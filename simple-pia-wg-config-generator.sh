#!/bin/bash

# Script to generate a WireGuard .conf file for PIA, selecting the lowest latency server in a region

# Set umask to restrict file permissions
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo "DEBUG: $1"
    fi
}

# Load credentials from file if available
if [ -f "$CREDENTIALS_FILE" ] && [ -s "$CREDENTIALS_FILE" ]; then
    echo "Reading credentials from file: $CREDENTIALS_FILE"
    PIA_USER=$(grep -E '^PIA_USER=' "$CREDENTIALS_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    PIA_PASS=$(grep -E '^PIA_PASS=' "$CREDENTIALS_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
fi

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
echo -n "Authenticating with PIA... "
TOKEN_RESPONSE=$(curl -s --location --request POST \
    "https://www.privateinternetaccess.com/api/client/v2/token" \
    --form "username=$PIA_USER" \
    --form "password=$PIA_PASS")
TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo -e "${RED}Failed to authenticate. Check your credentials.${NC}"
    exit 1
fi
echo -e "${GREEN}Success${NC}"

# Fetch server list
echo -n "Fetching server list... "
SERVER_LIST=$(curl -s "https://serverlist.piaservers.net/vpninfo/servers/v6")
if [ -z "$SERVER_LIST" ]; then
    echo -e "${RED}Failed to fetch server list.${NC}"
    exit 1
fi
echo -e "${GREEN}Success${NC}"

# Check if properties file exists and is not empty
if [ -f "$PROPERTIES_FILE" ] && [ -s "$PROPERTIES_FILE" ]; then
    echo "Reading regions from properties file: $PROPERTIES_FILE"
    REGION_IDS=$(cat "$PROPERTIES_FILE" | tr '\n' ' ')
else
    echo "Properties file not found or empty. Falling back to manual selection."

    # Display available regions
    echo "Available regions:"
    REGIONS=$(echo "$SERVER_LIST" | jq -r '.regions[] | [.id, .name] | join(" - ")' | sort -t '-' -k 2)
    REGION_ARRAY=()
    i=0
    while IFS= read -r line; do
        REGION_ARRAY[$i]="$line"
        echo "$i) ${REGION_ARRAY[$i]}"
        ((i++))
    done <<< "$REGIONS"

    # User selects a region
    echo -n "Enter the number of the region you want to use: "
    read CHOICE

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#REGION_ARRAY[@]}" ] || [ "$CHOICE" -lt 0 ]; then
        echo -e "${RED}Invalid selection.${NC}"
        exit 1
    fi

    SELECTED_REGION=$(echo "${REGION_ARRAY[$CHOICE]}" | cut -d' ' -f1)
    REGION_IDS="$SELECTED_REGION"
fi

# Generate config for the best server in each region
for SELECTED_REGION in $REGION_IDS; do    
    REGION_NAME=$(echo "$SERVER_LIST" | jq -r --arg reg "$SELECTED_REGION" '.regions[]? | select(.id == $reg) | .name' 2>/dev/null || true)    

    if [ -z "$REGION_NAME" ]; then
        echo -e "${RED}Invalid region ID: $SELECTED_REGION. Skipping.${NC}"
        continue
    fi
    echo -e "${GREEN}Selecting best server for region: $REGION_NAME ($SELECTED_REGION)${NC}"

    # Get WireGuard servers for the selected region
    WG_SERVERS_JSON=$(echo "$SERVER_LIST" | jq -c --arg reg "$SELECTED_REGION" '.regions[] | select(.id == $reg) | .servers.wg')

    SERVER_COUNT=$(echo "$WG_SERVERS_JSON" | jq 'length')
    if ! [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$SERVER_COUNT" -eq 0 ]; then
        echo -e "${RED}No WireGuard servers available for $REGION_NAME.${NC}"
        continue
    fi

    # Find the server with the lowest ping
    BEST_SERVER=""
    BEST_IP=""
    BEST_LATENCY=9999

    for ((i=0; i<SERVER_COUNT; i++)); do
        SERVER_IP=$(echo "$WG_SERVERS_JSON" | jq -r ".[$i].ip")
        SERVER_HOSTNAME=$(echo "$WG_SERVERS_JSON" | jq -r ".[$i].cn")

        echo -n "Testing latency for: $SERVER_HOSTNAME ($SERVER_IP)... "
        LATENCY=$(ping -c 2 -W 2 "$SERVER_IP" | tail -1 | awk -F '/' '{print $5}' | cut -d'.' -f1)

        if [[ -n "$LATENCY" && "$LATENCY" -lt "$BEST_LATENCY" ]]; then
            BEST_LATENCY=$LATENCY
            BEST_SERVER=$SERVER_HOSTNAME
            BEST_IP=$SERVER_IP
        fi

        echo -e "${GREEN}${LATENCY}ms${NC}"
    done

    if [ -z "$BEST_SERVER" ]; then
        echo -e "${RED}No responsive server available in $REGION_NAME.${NC}"
        continue
    fi

    echo -e "${GREEN}Best server: $BEST_SERVER ($BEST_IP) with ${BEST_LATENCY}ms latency.${NC}"

    # Generate WireGuard config file with latency in filename
    CONFIG_FILE="./configs/pia-${SELECTED_REGION}-${BEST_SERVER}_${BEST_LATENCY}ms.conf"
    mkdir -p "$(dirname "$CONFIG_FILE")"

    # Create WireGuard config
    cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = $(wg genkey)
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = example_public_key
Endpoint = $BEST_IP:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    echo -e "${GREEN}Config generated: $CONFIG_FILE${NC}"
done

