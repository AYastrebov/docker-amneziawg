#!/bin/bash

# Using bash because awg-quick is a bash script.

set -e

# Default interface name
INTERFACE="wg0"

# Check if an interface name is provided as an argument
if [ -n "$1" ]; then
    INTERFACE=$1
fi

# Path to the config file.
# awg-quick expects the config file to be at /etc/wireguard/<interface>.conf
CONFIG_FILE="/etc/wireguard/${INTERFACE}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Function to handle shutdown gracefully
shutdown() {
    echo "Shutting down WireGuard interface: $INTERFACE"
    awg-quick down "$CONFIG_FILE"
    exit 0
}

# Trap TERM and INT signals to call the shutdown function
trap shutdown SIGTERM SIGINT

# Bring the interface up.
# awg-quick up reads the config, creates the interface, sets routes,
# and starts the amneziawg-go daemon in the background.
echo "Bringing up WireGuard interface: $INTERFACE"
awg-quick up "$CONFIG_FILE"

# Keep the script running to keep the container alive.
# This pattern waits efficiently for a signal without consuming CPU.
echo "WireGuard interface is up. Container will remain running."
while true; do
    # Sleep in the background and wait for it
    sleep 86400 &
    wait $!
done
