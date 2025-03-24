#!/bin/bash

# Script to generate multiple WireGuard .conf files for PIA based on available servers in the selected region

# Check for required tools
for cmd in curl jq wg; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Error: $cmd is required. Please install it."
        exit 1
    fi
done

# Default values (hardcode here or override with env vars)
: "${DEBUG:=0}"              # Default to 0 (off) unless set
: "${PIA_USER:=p0123456}"  # Replace with your username (e.g., p0123456)
: "${PIA_PASS:=xxxxxxxx}"  # Replace with your password (e.g., xxxxxxxx)
CA_CERT="./ca/ca.rsa.4096.crt"         # Store in current directory

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Download CA certificate if not present
mkdir -p "$(dirname "$CA_CERT")"
if [ ! -f "$CA_CERT" ]; then
    echo -n "Downloading CA certificate... "
    curl -s -o "$CA_CERT" "https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt"
    if [ $? -eq 0 ] && [ -s "$CA_CERT" ]; then
        echo -e "${GREEN}Success${NC}"
    else
        echo -e "${RED}Failed to download CA certificate.${NC}"
        exit 1
    fi
else
    echo "CA certificate already exists at $CA_CERT"
fi

# Authenticate with PIA
TOKEN_RESPONSE=$(curl -s --location --request POST \
    "https://www.privateinternetaccess.com/api/client/v2/token" \
    --form "username=$PIA_USER" \
    --form "password=$PIA_PASS")
TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo -e "${RED}Failed to authenticate. Check your credentials.${NC}"
    exit 1
fi

# Fetch server list
SERVER_LIST=$(curl -s "https://serverlist.piaservers.net/vpninfo/servers/v6" | head -n 1)
if [ -z "$SERVER_LIST" ]; then
    echo -e "${RED}Failed to fetch server list.${NC}"
    exit 1
fi

# Build region list
echo "Available regions:"
REGIONS=$(echo "$SERVER_LIST" | jq -r '.regions[] | [.id, .name] | join(" - ")' | sort -t '-' -k 2)
REGION_ARRAY=()
i=0
while IFS= read -r line; do
    REGION_ARRAY[$i]="$line"
    echo "$i) ${REGION_ARRAY[$i]}"
    ((i++))
done <<< "$REGIONS"

# Select a region
echo -n "Enter the number of the region you want to use: "
read CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#REGION_ARRAY[@]}" ] || [ "$CHOICE" -lt 0 ]; then
    echo -e "${RED}Invalid selection.${NC}"
    exit 1
fi

SELECTED_REGION=$(echo "${REGION_ARRAY[$CHOICE]}" | cut -d' ' -f1)
REGION_NAME=$(echo "${REGION_ARRAY[$CHOICE]}" | cut -d'-' -f2- | sed 's/^ *//')

# Get all WireGuard servers for the selected region
WG_SERVERS_JSON=$(echo "$SERVER_LIST" | jq -c --arg reg "$SELECTED_REGION" '.regions[] | select(.id == $reg) | .servers.wg')
SERVER_COUNT=$(echo "$WG_SERVERS_JSON" | jq 'length')

echo -e "${GREEN}Found $SERVER_COUNT WireGuard servers for $REGION_NAME.${NC}"

# Generate config for each WG server
for ((i=0; i<SERVER_COUNT; i++)); do
    SERVER_IP=$(echo "$WG_SERVERS_JSON" | jq -r ".[$i].ip")
    SERVER_HOSTNAME=$(echo "$WG_SERVERS_JSON" | jq -r ".[$i].cn")

    echo -e "${GREEN}Generating config for: $SERVER_HOSTNAME ($SERVER_IP)...${NC}"

    # Generate WireGuard keys
    wg genkey > wg_temp.key
    PRIVATE_KEY=$(cat wg_temp.key)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    rm -f wg_temp.key

    # Register key with PIA WireGuard API
    WG_RESPONSE=$(curl -s -G \
        --connect-to "$SERVER_HOSTNAME::$SERVER_IP:" \
        --cacert "$CA_CERT" \
        --data-urlencode "pt=$TOKEN" \
        --data-urlencode "pubkey=$PUBLIC_KEY" \
        "https://$SERVER_HOSTNAME:1337/addKey")

    STATUS=$(echo "$WG_RESPONSE" | jq -r '.status')
    if [ "$STATUS" != "OK" ]; then
        echo -e "${RED}Failed to register key on server $SERVER_HOSTNAME.${NC}"
        continue
    fi

    SERVER_KEY=$(echo "$WG_RESPONSE" | jq -r '.server_key')
    SERVER_PORT=$(echo "$WG_RESPONSE" | jq -r '.server_port')
    DNS_SERVERS=$(echo "$WG_RESPONSE" | jq -r '.dns_servers | join(", ")')
    PEER_IP=$(echo "$WG_RESPONSE" | jq -r '.peer_ip')

    # Generate configuration file
    CONFIG_FILE="./configs/pia-${SELECTED_REGION}-${SERVER_HOSTNAME}.conf"
    mkdir -p "$(dirname "$CONFIG_FILE")"

    cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $PEER_IP/32
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_KEY
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    echo -e "${GREEN}Config generated: $CONFIG_FILE${NC}"
done
