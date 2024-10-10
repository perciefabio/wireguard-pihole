#!/bin/bash

read -p "Please enter the public IP address: " SERVER_PUB_IP
echo "You entered the public IP address: $SERVER_PUB_IP"

# Determine the default network interface
SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
if [ -z "$SERVER_NIC" ]; then
    echo "Error: Unable to determine the default network interface."
    exit 1
fi

SERVER_PUB_NIC="$SERVER_NIC"
SERVER_WG_NIC="wg0"
SERVER_WG_IPV4="10.66.66.1"
SERVER_PORT="56318"
ALLOWED_IPS="0.0.0.0/0"
CLIENT_DNS_1="1.1.1.1"

BASE_DIR="/etc/wireguard"
CLIENT_CONF_DIR="${BASE_DIR}/client_configs"
mkdir -p "$CLIENT_CONF_DIR" || { echo "Error: Failed to create client configs directory."; exit 1; }
chmod 700 "$CLIENT_CONF_DIR"

function installWireGuard() {
    apt-get update || { echo "Error: Failed to update package lists."; exit 1; }
    apt-get install -y wireguard iptables resolvconf qrencode || { echo "Error: Failed to install required packages."; exit 1; }

    mkdir -p "$BASE_DIR"
    chmod 600 -R "$BASE_DIR"

    SERVER_PRIV_KEY=$(wg genkey)
    SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

    if pgrep firewalld; then
        FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
        echo "PostUp = firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade'"
    else
        echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
    fi

    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/wg.conf
    sysctl --system || { echo "Error: Failed to apply sysctl settings."; exit 1; }

    systemctl start "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to start wg-quick service."; exit 1; }
    systemctl enable "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to enable wg-quick service."; exit 1; }

    newClient
    echo "If you want to add more clients, simply run this script again!"
}

function newClient() {
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

    read -rp "Client name: " CLIENT_NAME

    # Check if the CLIENT_NAME is empty
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
        ((DOT_IP++))
        if [[ ${DOT_IP} -gt 254 ]]; then
            echo "The subnet configured supports only 253 clients."
            exit 1
        fi
    done

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

    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}") || { echo "Error: Failed to sync WireGuard configuration."; exit 1; }

    if command -v qrencode &>/dev/null; then
        echo -e "\nHere is your client config file as a QR Code:\n"
        qrencode -t ansiutf8 -l L < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
        echo ""
    fi

    echo "Your client config file is in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
}

installWireGuard
