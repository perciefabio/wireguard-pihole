# Welcome to the WireGuard-Pi-hole Wiki!

## Overview

With this project, I aim to simplify the setup of a VPN server with an integrated ad blocker. This setup utilizes **WireGuard**, one of the fastest and safest VPN protocols available, along with **Pi-hole** as a DNS filter for blocking ads and trackers.

## Quick Start Guide

Follow these steps to get your VPN server up and running on an Ubuntu Server:

### Step 1: Switch to Root

Open your terminal and switch to the root user:

`sudo -i`

### Step 2: Clone the Repository and Run the Setup Script

Execute the following command to clone the repository and run the setup script:

`git clone https://github.com/perciefabio/wireguard-pihole.git && cd wireguard-pihole && chmod 777 VPN.sh && ./VPN.sh`


### QR Code Generation

Please note that the QR code generation tool might require a few attempts to output a functional QR code. While scanning with the WireGuard app, simply enter **1** if the QR code is not recognized. After successfully scanning, enter **2** to exit the tool.

### Adding Additional Clients

To add an additional client, simply run the setup script again in the **wireguard-pihole** directory:

`./VPN.sh`


## Features

- **Fast & Secure**: Utilizes WireGuard for a lightweight, high-performance VPN.
- **Ad Blocking**: Integrates Pi-hole for effective ad and tracker blocking at the network level.
- **Easy Setup**: Designed for straightforward installation with minimal configuration.

## Troubleshooting

If you encounter issues during the setup, consider the following:

- Ensure that your Ubuntu Server is up to date.
- Make sure you have the necessary permissions to execute the scripts.
- If QR code generation fails repeatedly, check if the required dependencies are installed.
- **Check Firewall Settings**: The UDP port **56318** needs to be open on your cloud provider. Ensure that this port is allowed in your security group or firewall settings.

## Contributing

If you have suggestions, improvements, or issues, feel free to open an issue or submit a pull request on GitHub.

## License

This project is licensed under the [MIT License](LICENSE).
