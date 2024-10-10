#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status.

# Prompt for the public IP address
read -p "Please enter the public IP address: " SERVER_PUB_IP

# Validate the public IP address format
if ! [[ $SERVER_PUB_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid IP address format. Please enter a valid public IP."
    exit 1
fi
echo "You entered the public IP address: $SERVER_PUB_IP"

# Network interface configuration
SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
SERVER_PUB_NIC="$SERVER_NIC"
SERVER_WG_NIC="wg0"
SERVER_WG_IPV4="10.66.66.1"
SERVER_PORT="56318"
ALLOWED_IPS="0.0.0.0/0"
CLIENT_DNS_1="1.1.1.1"

BASE_DIR="/etc/wireguard"
CLIENT_CONF_DIR="${BASE_DIR}/client_configs"

# Create the client configuration directory
mkdir -p "$CLIENT_CONF_DIR"
chmod 700 "$CLIENT_CONF_DIR"

function installWireGuard() {
    echo "Updating package list..."
    apt-get update

    echo "Installing WireGuard and required packages..."
    apt-get install -y wireguard iptables resolvconf qrencode || {
        echo "Error installing required packages."
        exit 1
    }

    echo "Creating base directory for WireGuard..."
    mkdir -p "$BASE_DIR"
    chmod 600 -R "$BASE_DIR"

    echo "Generating server keys..."
    SERVER_PRIV_KEY=$(wg genkey)
    SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

    # Configure firewall rules
    if pgrep firewalld; then
        echo "Configuring firewall rules using firewalld..."
        FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
        echo "PostUp = firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'" > "${BASE_DIR}/${SERVER_WG_NIC}.conf"
    else
        echo "Configuring firewall rules using iptables..."
        echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" > "${BASE_DIR}/${SERVER_WG_NIC}.conf"
    fi

    echo "Enabling IP forwarding..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/wg.conf
    sysctl --system || {
        echo "Failed to enable IP forwarding."
        exit 1
    }

    echo "Starting WireGuard service..."
    systemctl start "wg-quick@${SERVER_WG_NIC}" || {
        echo "Failed to start WireGuard service."
        exit 1
    }
    systemctl enable "wg-quick@${SERVER_WG_NIC}" || {
        echo "Failed to enable WireGuard service on boot."
        exit 1
    }

    newClient
    echo "If you want to add more clients, you simply need to run this script again!"
    systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
    WG_RUNNING=$?
}

function newClient() {
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"
    
    read -rp "Client name: " CLIENT_NAME

    # Validate client name
    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Client name cannot be empty."
        exit 1
    fi

    # Determine the next available IP address
    for DOT_IP in {2..254}; do
        DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "${BASE_DIR}/${SERVER_WG_NIC}.conf")
        if [[ ${DOT_EXISTS} == '0' ]]; then
            break
        fi
    done

    if [[ ${DOT_EXISTS} == '1' ]]; then
        echo "The subnet configured supports only 253 clients."
        exit 1
    fi

    BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
    CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"

    CLIENT_PRIV_KEY=$(wg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
    CLIENT_PRE_SHARED_KEY=$(wg genpsk)

    HOME_DIR="$CLIENT_CONF_DIR"
    
    echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_1}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" > "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

    echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32" >> "${BASE_DIR}/${SERVER_WG_NIC}.conf"

    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

    if command -v qrencode &>/dev/null; then
        echo -e "\nHere is your client config file as a QR Code:"
        qrencode -t ansiutf8 -l L < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
    fi

    echo -e "Your client config file is located at ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
}

installWireGuard
