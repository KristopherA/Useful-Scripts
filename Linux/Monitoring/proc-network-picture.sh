#!/usr/bin/env bash
# proc-network-picture.sh
# Uses only /proc plus basic shell tools to map PIDs to network sockets.
# No nethogs, iftop, ss, netstat, or lsof required - useful on minimal hosts
# and containers.
#
# Usage:
#   sudo ./proc-network-picture.sh              # all LISTEN/ESTABLISHED/UDP sockets
#   sudo ./proc-network-picture.sh <PID>        # one PID only
#   sudo ./proc-network-picture.sh '' --all     # include every TCP state
#
# Requirements: Linux /proc, bash, awk, sed, grep, sort, readlink.
#               Run as root to see sockets owned by other users.

set -u

TARGET_PID="${1:-}"
SHOW_ALL="${2:-}"

hex_to_dec() {
  printf "%d" "0x$1" 2>/dev/null
}

hex_ip_to_ipv4() {
  local hex="$1"
  local a b c d

  a="${hex:6:2}"
  b="${hex:4:2}"
  c="${hex:2:2}"
  d="${hex:0:2}"

  printf "%d.%d.%d.%d" "0x$a" "0x$b" "0x$c" "0x$d"
}

# /proc/net/{tcp6,udp6} store the address as four 32-bit words, each in host
# (little-endian) byte order. Output is the uncompressed IPv6 form in brackets.
hex_ip_to_ipv6() {
  local hex="$1" out="" w word
  for w in 0 8 16 24; do
    word="${hex:w:8}"
    word="${word:6:2}${word:4:2}${word:2:2}${word:0:2}"
    out="${out}${word:0:4}:${word:4:4}:"
  done
  out="${out%:}"
  printf "[%s]" "$(echo "$out" | tr 'A-F' 'a-f')"
}

hex_ip_to_ip() {
  if [ "${#1}" -eq 32 ]; then
    hex_ip_to_ipv6 "$1"
  else
    hex_ip_to_ipv4 "$1"
  fi
}

tcp_state() {
  case "$1" in
    01) echo "ESTABLISHED" ;;
    02) echo "SYN_SENT" ;;
    03) echo "SYN_RECV" ;;
    04) echo "FIN_WAIT1" ;;
    05) echo "FIN_WAIT2" ;;
    06) echo "TIME_WAIT" ;;
    07) echo "CLOSE" ;;
    08) echo "CLOSE_WAIT" ;;
    09) echo "LAST_ACK" ;;
    0A) echo "LISTEN" ;;
    0B) echo "CLOSING" ;;
    *) echo "$1" ;;
  esac
}

get_cmd() {
  local pid="$1"
  local cmd=""

  if [ -r "/proc/$pid/cmdline" ]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  fi

  if [ -z "$cmd" ] && [ -r "/proc/$pid/comm" ]; then
    cmd="$(cat "/proc/$pid/comm" 2>/dev/null)"
  fi

  echo "$cmd"
}

build_inode_map() {
  local pid fd inode cmd link

  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"

    if [ -n "$TARGET_PID" ] && [ "$pid" != "$TARGET_PID" ]; then
      continue
    fi

    [ -d "/proc/$pid/fd" ] || continue

    cmd="$(get_cmd "$pid")"

    for fd in /proc/"$pid"/fd/*; do
      [ -e "$fd" ] || continue

      link="$(readlink "$fd" 2>/dev/null || true)"

      case "$link" in
        socket:*)
          inode="$(echo "$link" | sed -n 's/socket:\[\([0-9]*\)\]/\1/p')"
          [ -n "$inode" ] && echo "$inode|$pid|${fd##*/}|$cmd"
          ;;
      esac
    done
  done
}

parse_proc_net_tcp() {
  local file="$1"
  local proto="$2"

  [ -r "$file" ] || return

  awk 'NR>1 {print $2, $3, $4, $10}' "$file" | while read -r local remote state inode; do
    lip_hex="${local%:*}"
    lport_hex="${local#*:}"
    rip_hex="${remote%:*}"
    rport_hex="${remote#*:}"

    local_ip="$(hex_ip_to_ip "$lip_hex")"
    remote_ip="$(hex_ip_to_ip "$rip_hex")"
    local_port="$(hex_to_dec "$lport_hex")"
    remote_port="$(hex_to_dec "$rport_hex")"
    state_name="$(tcp_state "$state")"

    echo "$inode|$proto|$state_name|$local_ip:$local_port|$remote_ip:$remote_port"
  done
}

parse_proc_net_udp() {
  local file="$1"
  local proto="$2"

  [ -r "$file" ] || return

  awk 'NR>1 {print $2, $3, $4, $10}' "$file" | while read -r local remote state inode; do
    lip_hex="${local%:*}"
    lport_hex="${local#*:}"
    rip_hex="${remote%:*}"
    rport_hex="${remote#*:}"

    local_ip="$(hex_ip_to_ip "$lip_hex")"
    remote_ip="$(hex_ip_to_ip "$rip_hex")"
    local_port="$(hex_to_dec "$lport_hex")"
    remote_port="$(hex_to_dec "$rport_hex")"

    echo "$inode|$proto|UDP|$local_ip:$local_port|$remote_ip:$remote_port"
  done
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

inode_map="$tmpdir/inodes.txt"
conn_map="$tmpdir/conns.txt"

build_inode_map | sort -u > "$inode_map"

parse_proc_net_tcp /proc/net/tcp TCP4 > "$conn_map"
parse_proc_net_tcp /proc/net/tcp6 TCP6 >> "$conn_map"
parse_proc_net_udp /proc/net/udp UDP4 >> "$conn_map"
parse_proc_net_udp /proc/net/udp6 UDP6 >> "$conn_map"

echo
echo "PROC NETWORK PICTURE"
echo "===================="
echo "Host: $(hostname)"
echo "Date: $(date)"
echo "Target PID: ${TARGET_PID:-ALL}"
echo

printf "%-8s %-6s %-6s %-14s %-24s %-24s %s\n" \
  "PID" "FD" "PROTO" "STATE" "LOCAL" "REMOTE" "COMMAND"

echo "---------------------------------------------------------------------------------------------------------------"

while IFS='|' read -r inode proto state local_addr remote_addr; do
  matches="$(grep "^$inode|" "$inode_map" 2>/dev/null || true)"

  [ -n "$matches" ] || continue

  echo "$matches" | while IFS='|' read -r _ pid fd cmd; do
    if [ "$SHOW_ALL" != "--all" ]; then
      case "$state" in
        LISTEN|ESTABLISHED|UDP) ;;
        *) continue ;;
      esac
    fi

    printf "%-8s %-6s %-6s %-14s %-24s %-24s %s\n" \
      "$pid" "$fd" "$proto" "$state" "$local_addr" "$remote_addr" "$cmd"
  done
done < "$conn_map"

echo
echo "SUMMARY BY PROCESS"
echo "=================="

awk -F'|' '
  {
    count[$2]++
    cmd[$2]=$4
  }
  END {
    for (pid in count) {
      printf "%-8s sockets=%-4s %s\n", pid, count[pid], cmd[pid]
    }
  }
' "$inode_map" | sort -t= -k2 -nr

echo
echo "USAGE"
echo "====="
echo "Show all active/listening sockets:"
echo "  sudo ./proc-network-picture.sh"
echo
echo "Show one PID only:"
echo "  sudo ./proc-network-picture.sh <PID>"
echo
echo "Include all TCP states:"
echo "  sudo ./proc-network-picture.sh '' --all"
echo
echo "Check sockets manually for one PID:"
echo "  sudo ls -la /proc/<pid>/fd | grep socket"
