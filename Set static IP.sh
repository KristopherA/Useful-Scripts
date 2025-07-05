#!/bin/bash

# Script to configure a static IP in Netplan for Ubuntu 22.04 LTS or higher

# Configuration variables (modify these as needed)
INTERFACE="eth0"              # Replace with your network interface (e.g., eth0, ens33)
STATIC_IP="XXX.XXX.XXX.XXX/24"   # Static IP address with CIDR notation
GATEWAY="XXX.XXX.XXX.XXX"          # Default gateway
DNS_SERVERS="XXX.XXX.XXX.XXX, XXX.XXX.XXX.XXX"  # DNS servers (comma-separated)
NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# Validate interface existence
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
  echo "Error: Network interface $INTERFACE does not exist."
  exit 1
fi

# Backup existing Netplan configuration
if [ -f "$NETPLAN_FILE" ]; then
  echo "Backing up existing Netplan configuration to $NETPLAN_FILE.bak"
  cp "$NETPLAN_FILE" "$NETPLAN_FILE.bak"
fi

# Create or overwrite Netplan configuration
echo "Creating Netplan configuration at $NETPLAN_FILE"
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $STATIC_IP
      routes: 
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS_SERVERS]
EOF

# Set proper permissions
chmod 600 "$NETPLAN_FILE"

# Test Netplan configuration
echo "Testing Netplan configuration..."
if ! netplan try; then
  echo "Error: Netplan configuration is invalid. Restoring backup."
  [ -f "$NETPLAN_FILE.bak" ] && mv "$NETPLAN_FILE.bak" "$NETPLAN_FILE"
  exit 1
fi

# Apply Netplan configuration
echo "Applying Netplan configuration..."
netplan apply

# Verify configuration
echo "Verifying network configuration..."
ip addr show "$INTERFACE"
echo "Static IP configuration complete."

exit 0