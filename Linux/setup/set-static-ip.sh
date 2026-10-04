#!/bin/bash
# set-static-ip.sh - Configure a static IPv4 address with Netplan.
#
# Writes a Netplan config for one interface, validates it with `netplan try`
# (auto-reverts after 120s if you lose connectivity and don't confirm), then applies it.
#
# Usage:
#   sudo ./set-static-ip.sh <interface> <ip/cidr> <gateway> <dns1[,dns2,...]>
#   sudo ./set-static-ip.sh eth0 192.0.2.10/24 192.0.2.1 192.0.2.53,198.51.100.53
#   # or via environment:
#   sudo INTERFACE=ens18 STATIC_IP=192.0.2.10/24 GATEWAY=192.0.2.1 DNS_SERVERS=192.0.2.53 ./set-static-ip.sh
#
# Requirements: root, netplan (systemd-networkd renderer).
# Supported:    Ubuntu 18.04+ (uses `routes: - to: default`, Netplan 0.103+ / Ubuntu 22.04+ recommended).
#
# Note: other files in /etc/netplan/ that configure the same interface (e.g. DHCP from
# cloud-init in 50-cloud-init.yaml) are merged and may conflict; review them first.

set -euo pipefail

# ---- Configuration (args > environment) -------------------------------------
INTERFACE="${1:-${INTERFACE:-}}"          # e.g. eth0, ens18
STATIC_IP="${2:-${STATIC_IP:-}}"          # e.g. 192.0.2.10/24
GATEWAY="${3:-${GATEWAY:-}}"              # e.g. 192.0.2.1
DNS_SERVERS="${4:-${DNS_SERVERS:-}}"      # comma-separated, e.g. 192.0.2.53,198.51.100.53
NETPLAN_FILE="${NETPLAN_FILE:-/etc/netplan/01-netcfg.yaml}"
# -----------------------------------------------------------------------------

usage() { sed -n '2,15p' "$0"; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if [[ -z "$INTERFACE" || -z "$STATIC_IP" || -z "$GATEWAY" || -z "$DNS_SERVERS" ]]; then
  echo "Error: interface, IP/CIDR, gateway and DNS servers are required." >&2
  usage
fi

if [[ "$STATIC_IP" != */* ]]; then
  echo "Error: STATIC_IP must include a prefix length, e.g. 192.0.2.10/24" >&2
  exit 1
fi

if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
  echo "Error: network interface $INTERFACE does not exist." >&2
  exit 1
fi

# Normalise "a, b,c" -> "a, b, c"
DNS_LIST="$(echo "$DNS_SERVERS" | tr -d ' ' | sed 's/,/, /g')"

BACKUP=""
if [[ -f "$NETPLAN_FILE" ]]; then
  BACKUP="$NETPLAN_FILE.bak.$(date +%Y%m%d%H%M%S)"
  echo "Backing up $NETPLAN_FILE to $BACKUP"
  cp -a "$NETPLAN_FILE" "$BACKUP"
fi

restore() {
  echo "Restoring previous configuration." >&2
  if [[ -n "$BACKUP" ]]; then
    cp -a "$BACKUP" "$NETPLAN_FILE"
  else
    rm -f "$NETPLAN_FILE"
  fi
}

echo "Writing $NETPLAN_FILE"
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $STATIC_IP
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS_LIST]
EOF
chmod 600 "$NETPLAN_FILE"

if ! netplan generate; then
  echo "Error: Netplan configuration is invalid." >&2
  restore
  exit 1
fi

echo "Testing configuration with 'netplan try' (press ENTER to accept)..."
if ! netplan try; then
  echo "Error: 'netplan try' failed or was not confirmed." >&2
  restore
  exit 1
fi

netplan apply
ip addr show "$INTERFACE"
echo "Static IP configuration complete."
