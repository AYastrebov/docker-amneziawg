#!/usr/bin/with-contenv bash

CONFIG_DIR="/config/amneziawg"
CONFIG_FILE="${CONFIG_DIR}/awg0.conf"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/awg0-client.conf" # Client config will be saved here

echo "Checking for existing AmneziaWG configuration at ${CONFIG_FILE}..."

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "No existing configuration found. Generating new AmneziaWG configuration..."

    # Generate server keys
    SERVER_PRIVATE_KEY=$(awg genkey)
    SERVER_PUBLIC_KEY=$(echo "${SERVER_PRIVATE_KEY}" | awg pubkey)
    PRESHARED_KEY=$(awg genpsk)

    # Generate random values for S1, S2, H1, H2, H3, H4
    # S1, S2: 1-255 (example range)
    S1=$(shuf -i 1-255 -n 1)
    S2=$(shuf -i 1-255 -n 1)
    # H1-H4: large random integers (using od for better randomness)
    H1=$(od -An -N4 -i /dev/urandom | awk '{print $1}')
    H2=$(od -An -N4 -i /dev/urandom | awk '{print $1}')
    H3=$(od -An -N4 -i /dev/urandom | awk '{print $1}')
    H4=$(od -An -N4 -i /dev/urandom | awk '{print $1}')

    # Generate random values for Jc, Jmin, Jmax within specified constraints
    # Jc: 1 to 128
    JC=$(shuf -i 1-128 -n 1)
    
    # Jmin: 1 to 1279
    JMIN=$(shuf -i 1-1279 -n 1)
    # Jmax: Jmin to 1280
    JMAX=$(shuf -i ${JMIN}-1280 -n 1)

    # Generate client keys for example output and peer configuration
    CLIENT_PRIVATE_KEY=$(awg genkey)
    CLIENT_PUBLIC_KEY=$(echo "${CLIENT_PRIVATE_KEY}" | awg pubkey)

    # Default IP addresses and port
    SERVER_TUNNEL_IP="10.8.1.1/24"
    PUBLIC_PORT="51820"
    CLIENT_TUNNEL_IP="10.8.1.2/24"
    ALLOWED_IPS="0.0.0.0/0, ::/0" # Route all IPv4 and IPv6 traffic through the tunnel

    # Create server configuration file
    cat <<EOF > "${CONFIG_FILE}"
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${SERVER_TUNNEL_IP}
ListenPort = ${PUBLIC_PORT}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PresharedKey = ${PRESHARED_KEY}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_TUNNEL_IP}
EOF

    echo "Generated server configuration at ${CONFIG_FILE}"
    echo "----------------------------------------------------"
    cat "${CONFIG_FILE}"
    echo "----------------------------------------------------"

    echo " "
    echo "----------------------------------------------------"
    echo "Client Configuration (save this for your client device):"
    echo "----------------------------------------------------"
    echo "[Interface]"
    echo "PrivateKey = ${CLIENT_PRIVATE_KEY}"
    echo "Address = ${CLIENT_TUNNEL_IP}"
    echo "Jc = ${JC}"
    echo "Jmin = ${JMIN}"
    echo "Jmax = ${JMAX}"
    echo "S1 = ${S1}"
    echo "S2 = ${S2}"
    echo "H1 = ${H1}"
    echo "H2 = ${H2}"
    echo "H3 = ${H3}"
    echo "H4 = ${H4}"
    echo ""
    echo "[Peer]"
    echo "PresharedKey = ${PRESHARED_KEY}"
    echo "PublicKey = ${SERVER_PUBLIC_KEY}"
    echo "Endpoint = <YOUR_SERVER_PUBLIC_IP>:${PUBLIC_PORT}"
    echo "AllowedIPs = ${ALLOWED_IPS}"
    echo "----------------------------------------------------"
    echo " "
    echo "REMEMBER TO REPLACE <YOUR_SERVER_PUBLIC_IP> WITH YOUR ACTUAL SERVER'S PUBLIC IP ADDRESS!"
    echo "You can also adjust AllowedIPs for your specific routing needs."

    # Save client config to a file for easy retrieval
    cat <<EOF > "${CLIENT_CONFIG_FILE}"
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_TUNNEL_IP}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PresharedKey = ${PRESHARED_KEY}
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = <YOUR_SERVER_PUBLIC_IP>:${PUBLIC_PORT}
AllowedIPs = ${ALLOWED_IPS}
EOF
    echo "Client configuration also saved to ${CLIENT_CONFIG_FILE}"

else
    echo "Existing configuration found at ${CONFIG_FILE}. Skipping generation."
fi
