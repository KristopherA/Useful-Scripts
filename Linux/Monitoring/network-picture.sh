#!/usr/bin/env bash
# network-picture.sh
# Shows: interfaces, IPs, routes, DNS, listening ports, active connections,
# bandwidth by process, bandwidth by remote host, and socket/process mapping.
#
# Usage:        sudo ./network-picture.sh [INTERFACE]
#               (interface is auto-detected from the default route if omitted)
# Requirements: bash, iproute2 (ip, ss); optional: resolvectl, nethogs, iftop.
#               nethogs/iftop are interactive - press q to continue.

set -euo pipefail

# --- Configuration (override via environment) ---
# Any routable address; only used to ask the kernel which interface it would use.
ROUTE_PROBE_IP="${ROUTE_PROBE_IP:-1.1.1.1}"

IFACE="${1:-}"

need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Run as root:"
    echo "sudo $0 ${IFACE:-}"
    exit 1
  fi
}

pick_iface() {
  if [ -n "$IFACE" ]; then
    echo "$IFACE"
    return
  fi

  ip route get "$ROUTE_PROBE_IP" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}'
}

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

need_root

IFACE="$(pick_iface)"

if [ -z "$IFACE" ]; then
  echo "Could not detect active interface."
  echo "Usage: sudo $0 eth0"
  exit 1
fi

clear 2>/dev/null || true   # (fixed: aborted under set -e when TERM is unset)
echo "NETWORK PICTURE REPORT"
echo "Host: $(hostname)"
echo "Date: $(date)"
echo "Interface: $IFACE"

section "1. INTERFACES"
ip -br addr

section "2. DEFAULT ROUTES"
ip route

section "3. DNS"
if command -v resolvectl >/dev/null 2>&1; then
  resolvectl status | sed -n '1,80p' || true
else
  cat /etc/resolv.conf
fi

section "4. LISTENING PORTS"
ss -tulpen

section "5. ACTIVE TCP CONNECTIONS WITH PROCESSES"
ss -tnp

section "6. TOP CONNECTION STATES"
ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -nr

section "7. BANDWIDTH BY PROCESS - NETHOGS"
if command -v nethogs >/dev/null 2>&1; then
  echo "Press q to exit nethogs."
  sleep 2
  nethogs "$IFACE"
else
  echo "nethogs not installed."
  echo "Install:"
  echo "sudo apt install nethogs -y"
  echo "sudo dnf install nethogs -y"
fi

section "8. BANDWIDTH BY REMOTE HOST - IFTOP"
if command -v iftop >/dev/null 2>&1; then
  echo "Press q to exit iftop."
  sleep 2
  iftop -i "$IFACE"
else
  echo "iftop not installed."
  echo "Install:"
  echo "sudo apt install iftop -y"
  echo "sudo dnf install iftop -y"
fi

section "9. PER-PROCESS SOCKET SUMMARY"
for pid in $(ls /proc | grep -E '^[0-9]+$' | head -n 5000); do
  if [ -d "/proc/$pid/fd" ]; then
    sockets="$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -c 'socket:' || true)"
    if [ "$sockets" -gt 0 ]; then
      cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-100 || true)"
      [ -z "$cmd" ] && cmd="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
      echo "PID=$pid SOCKETS=$sockets CMD=$cmd"
    fi
  fi
done | sort -t= -k3 -nr | head -n 30   # (fixed: sort by socket count, was sorting by PID)

section "10. QUICK DIAGNOSIS COMMANDS"
cat <<EOF
Find interface:
ip link show

Bandwidth by process:
sudo nethogs $IFACE

Bandwidth by remote host:
sudo iftop -i $IFACE

Open ports:
sudo ss -tulpen

Active connections:
sudo ss -tnp

Find process using a port:
sudo ss -ltnp | grep ':PORT'

Inspect one PID:
sudo ls -la /proc/PID/fd | grep socket
sudo cat /proc/PID/cmdline | tr '\\0' ' '
EOF
