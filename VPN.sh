#!/bin/bash

# Get the server's network interface and configuration
SERVER_NIC="$(ip -4 route ls | grep default | awk '{print $5}' | head -1)"
SERVER_PUB_NIC="$SERVER_NIC"
SERVER_WG_NIC="wg0"
SERVER_WG_IPV4="10.10.10.1"
SERVER_PORT="56318"
ALLOWED_IPS="0.0.0.0/0"
CLIENT_DNS_1="$(ip -4 addr show "$SERVER_NIC" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')"
BASE_DIR="/etc/wireguard"
CLIENT_CONF_DIR="${BASE_DIR}/client_configs"
mkdir -p "$CLIENT_CONF_DIR" 
chmod 700 "$CLIENT_CONF_DIR"  # More restrictive permissions

# Get the server's public IP address
SERVER_PUB_IP="$(curl -s ifconfig.me)"

function installWireGuard() {
    sudo apt-get update
    sudo apt-get install -y wireguard iptables resolvconf qrencode || { echo "Error: Failed to install packages."; exit 1; }

    # Check if the server configuration already exists
    if [ ! -f "/etc/wireguard/${SERVER_WG_NIC}.conf" ]; then
        SERVER_PRIV_KEY="$(wg genkey)"
        SERVER_PUB_KEY="$(echo "${SERVER_PRIV_KEY}" | wg pubkey)"

        cat <<EOF | sudo tee "/etc/wireguard/${SERVER_WG_NIC}.conf" > /dev/null
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

        echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/wg.conf > /dev/null
        sudo sysctl -p /etc/sysctl.d/wg.conf  # Apply sysctl changes

        sudo systemctl start "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to start wg-quick service."; exit 1; }
        sudo systemctl enable "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to enable wg-quick service."; exit 1; }
    else
        SERVER_PRIV_KEY="$(grep PrivateKey /etc/wireguard/${SERVER_WG_NIC}.conf | awk '{print $3}')"
        SERVER_PUB_KEY="$(echo "${SERVER_PRIV_KEY}" | wg pubkey)"
    fi

    read -rp "Client name: " CLIENT_NAME

    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Error: Client name cannot be empty."
        exit 1
    fi

    DOT_IP=2
    while true; do
        DOT_EXISTS="$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "${BASE_DIR}/${SERVER_WG_NIC}.conf")"
        if [[ ${DOT_EXISTS} == '0' ]]; then
            break
        fi
        DOT_IP=$((DOT_IP + 1))  # Increment the IP suffix
    done

    BASE_IP="$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')"
    CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"

    CLIENT_PRIV_KEY="$(wg genkey)"
    CLIENT_PUB_KEY="$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)"
    CLIENT_PRE_SHARED_KEY="$(wg genpsk)"

    HOME_DIR="$CLIENT_CONF_DIR"

    # Create client configuration with the correct endpoint
    cat <<EOF > "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_1}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${SERVER_PUB_IP}:${SERVER_PORT}
AllowedIPs = ${ALLOWED_IPS}
EOF

    # Add the client to the server configuration
    echo -e "\n### Client ${CLIENT_NAME}" | sudo tee -a "${BASE_DIR}/${SERVER_WG_NIC}.conf" > /dev/null
    cat <<EOF | sudo tee -a "${BASE_DIR}/${SERVER_WG_NIC}.conf" > /dev/null
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32
EOF

    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}") || { echo "Error: Failed to sync WireGuard configuration."; exit 1; }
}

installWireGuard

function installpihole() {
    curl -sSL https://install.pi-hole.net | bash -s -- --unattended
}

installpihole

function ad_list() {

        adlists=(
   
    )


 for adlist in "${adlists[@]}"; do
        echo "$adlist" | sudo tee -a /etc/pihole/adlists.list > /dev/null
    done

    pihole -g
}

ad_list

function restart_services() {
    echo "Restarting WireGuard and Pi-hole services..."
    sudo systemctl restart "wg-quick@${SERVER_WG_NIC}" || { echo "Error: Failed to restart WireGuard service."; exit 1; }
    sudo systemctl restart pihole-FTL || { echo "Error: Failed to restart Pi-hole service."; exit 1; }
    echo "Services restarted successfully."
}

restart_services

function displayqr() {
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

displayqr


