#!/bin/bash

SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
SERVER_PUB_NIC="$SERVER_NIC"
SERVER_WG_NIC="wg0"
SERVER_WG_IPV4="10.10.10.1"
SERVER_PORT="56318"
ALLOWED_IPS="0.0.0.0/0"
CLIENT_DNS_1="1.1.1.1"
BASE_DIR="/etc/wireguard"
CLIENT_CONF_DIR="${BASE_DIR}/client_configs"
mkdir -p "$CLIENT_CONF_DIR" 
chmod 777 "$CLIENT_CONF_DIR"

# Get server's public IP address (you can also manually set this)
SERVER_PUB_IP=$(curl -s ifconfig.me)

function installWireGuard() {
    apt-get update
    apt-get install -y wireguard iptables resolvconf qrencode

    # Check if the server configuration already exists
    if [ ! -f "/etc/wireguard/${SERVER_WG_NIC}.conf" ]; then
        SERVER_PRIV_KEY=$(wg genkey)
        SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

        cat <<EOF > "/etc/wireguard/${SERVER_WG_NIC}.conf"
[Interface]
PrivateKey = ${SERVER_PRIV_KEY}
Address = ${SERVER_WG_IPV4}/24
ListenPort = ${SERVER_PORT}

PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
EOF

        echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/wg.conf

        systemctl start "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to start wg-quick service."; exit 1; }
        systemctl enable "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to enable wg-quick service."; exit 1; }
    else
        SERVER_PRIV_KEY=$(grep PrivateKey /etc/wireguard/${SERVER_WG_NIC}.conf | awk '{print $3}')
        SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)
    fi

    read -rp "Client name: " CLIENT_NAME

    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Error: Client name cannot be empty."
        exit 1
    fi

    DOT_IP=2
    while true; do
        DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "${BASE_DIR}/${SERVER_WG_NIC}.conf")
        if [[ ${DOT_EXISTS} == '0' ]]; then
            break
        fi
        DOT_IP=$((DOT_IP + 1)) # Increment the IP suffix
    done

    BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
    CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"

    CLIENT_PRIV_KEY=$(wg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
    CLIENT_PRE_SHARED_KEY=$(wg genpsk)

    HOME_DIR="$CLIENT_CONF_DIR"

    # Create client configuration with the correct endpoint
    echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_1}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${SERVER_PUB_IP}:${SERVER_PORT}
AllowedIPs = ${ALLOWED_IPS}" > "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

    # Add the client to the server configuration
    echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32" >> "${BASE_DIR}/${SERVER_WG_NIC}.conf"

    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}") || { echo "Error: Failed to sync WireGuard configuration."; exit 1; }

    echo -e "\nHere is your client config file as a QR Code:\n"

    while true; do
        qrencode -t ansiutf8 -l L < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
        echo "QR codes generated with qrencode can have errors and may not be recognized."
        echo "If it does not work, enter 1 to generate a new code, or press 2 to exit."
        read -rp "Your choice: " CHOICE

        if [[ "$CHOICE" == "1" ]]; then
            echo "Generating a new QR code..."
            continue  
        elif [[ "$CHOICE" == "2" ]]; then
            echo "Exiting."
            exit 0  
        else
            echo "Invalid choice. Please enter 1 to generate a new code or 2 to exit."
        fi
    done

    echo "Your client config file is in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
}

installWireGuard
