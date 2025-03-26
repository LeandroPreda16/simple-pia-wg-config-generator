#!/bin/bash

# Script to generate a WireGuard .conf file for the best PIA server based on ping response

umask 077

# Check for required tools
for cmd in curl jq wg ping; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Error: $cmd is required. Please install it."
        exit 1
    fi
done

# Default values
: "${DEBUG:=0}"
: "${PIA_USER:=your_pia_username}"
: "${PIA_PASS:=your_pia_password}"
CA_CERT="./ca/ca.rsa.4096.crt"
PROPERTIES_FILE="./regions.properties"
CREDENTIALS_FILE="./credentials.properties"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo "DEBUG: $1"
    fi
}

# Load credentials
if [ -f "$CREDENTIALS_FILE" ] && [ -s "$CREDENTIALS_FILE" ]; then
    debug "Reading credentials from file: $CREDENTIALS_FILE"
    PIA_USER=$(grep -E '^PIA_USER=' "$CREDENTIALS_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    PIA_PASS=$(grep -E '^PIA_PASS=' "$CREDENTIALS_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
fi

# Download CA certificate if not present
mkdir -p "$(dirname "$CA_CERT")"
if [ ! -f "$CA_CERT" ]; then
    debug "Downloading CA certificate..."
    curl -s -o "$CA_CERT" "https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt"
fi

# Authenticate with PIA
echo -n "Authenticating with PIA... "
TOKEN_RESPONSE=$(curl -s --location --request POST \
    "https://www.privateinternetaccess.com/api/client/v2/token" \
    --form "username=$PIA_USER" \
    --form "password=$PIA_PASS")
TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token')

debug "Token Response: $TOKEN_RESPONSE"

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo -e "${RED}Failed to authenticate. Check your credentials.${NC}"
    exit 1
fi

echo -e "${GREEN}Success${NC}"

# Fetch server list
debug "Fetching server list..."
SERVER_LIST=$(curl -s "https://serverlist.piaservers.net/vpninfo/servers/v6" | head -n 1)
if [ -z "$SERVER_LIST" ]; then
    echo -e "${RED}Failed to fetch server list.${NC}"
    exit 1
fi

echo -e "${GREEN}List acquired : Success${NC}"

#debug "Server List: $SERVER_LIST"

# Select a region
if [ -f "$PROPERTIES_FILE" ] && [ -s "$PROPERTIES_FILE" ]; then
    debug "Reading regions from properties file: $PROPERTIES_FILE"
    REGION_IDS=$(cat "$PROPERTIES_FILE" | tr '\n' ' ')
else
    echo "Available regions:"
    REGIONS=$(echo "$SERVER_LIST" | jq -r '.regions[] | [.id, .name] | join(" - ")' | sort -t '-' -k 2)
    REGION_ARRAY=()
    i=0
    while IFS= read -r line; do
        REGION_ARRAY[$i]="$line"
        echo "$i) ${REGION_ARRAY[$i]}"
        ((i++))
    done <<< "$REGIONS"

    echo -n "Enter the number of the region you want to use: "
    read CHOICE

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#REGION_ARRAY[@]}" ] || [ "$CHOICE" -lt 0 ]; then
        echo -e "${RED}Invalid selection.${NC}"
        exit 1
    fi

    SELECTED_REGION=$(echo "${REGION_ARRAY[$CHOICE]}" | cut -d' ' -f1)
fi

# Generate configs for each region in the list
for SELECTED_REGION in $REGION_IDS; do    

    debug "Selected Region: $SELECTED_REGION"

    # Get the list of WireGuard servers
    WG_SERVERS_JSON=$(echo "$SERVER_LIST" | jq -c --arg reg "$SELECTED_REGION" '.regions[] | select(.id == $reg) | .servers.wg')
    debug "WireGuard Servers JSON: $WG_SERVERS_JSON"

    BEST_SERVER=""
    BEST_PING=999999
    BEST_HOST=""

    for server in $(echo "$WG_SERVERS_JSON" | jq -r '.[].ip'); do
        PING_TIME=$(ping -c 3 -q "$server" | awk -F '/' 'END {print ($5 ? $5 : "999999")}')
        SERVER_HOSTNAME=$(echo "$WG_SERVERS_JSON" | jq -r ".[] | select(.ip == \"$server\") | .cn")

        echo "Ping IP $server: ${PING_TIME}ms as ${SELECTED_REGION} - ${SERVER_HOSTNAME}"
        
        if [ "$PING_TIME" != "999999" ] && (( $(echo "$PING_TIME < $BEST_PING" | bc -l) )); then
            BEST_PING="$PING_TIME"
            BEST_SERVER="$server"
            BEST_HOST="$SERVER_HOSTNAME"
        fi
    done

    if [ -z "$BEST_SERVER" ]; then
        echo -e "${RED}No reachable server found.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Best server: $BEST_SERVER with ${BEST_PING}ms${NC}"
    debug "Best Server: $BEST_SERVER, Ping: $BEST_PING. Host: $BEST_HOST"

    # Generate WireGuard keys
    wg genkey > wg_temp.key
    PRIVATE_KEY=$(cat wg_temp.key)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    rm -f wg_temp.key

    debug "Generated WireGuard keys"

    # Register key with PIA WireGuard API
    debug "BEST_HOST: $BEST_HOST"
    debug "BEST_SERVER: $BEST_SERVER"
    debug "CA_CERT: $CA_CERT"
    debug "TOKEN: $TOKEN"
    debug "PUBLIC_KEY: $PUBLIC_KEY"


    WG_RESPONSE=$(curl -s -G \
        --connect-to "$BEST_HOST::$BEST_SERVER:" \
        --cacert "$CA_CERT" \
        --data-urlencode "pt=$TOKEN" \
        --data-urlencode "pubkey=$PUBLIC_KEY" \
        "https://$BEST_HOST:1337/addKey")

    debug "WireGuard API Response: $WG_RESPONSE"

    STATUS=$(echo "$WG_RESPONSE" | jq -r '.status')
    if [ "$STATUS" != "OK" ]; then
        echo -e "${RED}Failed to register key with server $BEST_SERVER.${NC} "
        exit 1
    fi

    SERVER_KEY=$(echo "$WG_RESPONSE" | jq -r '.server_key')
    SERVER_PORT=$(echo "$WG_RESPONSE" | jq -r '.server_port')
    DNS_SERVERS=$(echo "$WG_RESPONSE" | jq -r '.dns_servers | join(", ")')
    PEER_IP=$(echo "$WG_RESPONSE" | jq -r '.peer_ip')

    debug "Server Key: $SERVER_KEY, Server Port: $SERVER_PORT, DNS: $DNS_SERVERS, Peer IP: $PEER_IP"

    # Generate WireGuard configuration file
    CONFIG_FILE="./configs/pia-${SELECTED_REGION}-${SERVER_HOSTNAME}-${BEST_PING}ms.conf"
    mkdir -p "$(dirname "$CONFIG_FILE")"

cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $PEER_IP/32
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_KEY
Endpoint = $BEST_SERVER:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    echo -e "${GREEN}Config generated: $CONFIG_FILE${NC}"
    debug "Config file created at: $CONFIG_FILE"

done
