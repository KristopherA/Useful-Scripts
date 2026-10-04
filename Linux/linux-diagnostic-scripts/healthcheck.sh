#!/usr/bin/env bash
# healthcheck.sh - read-only Ubuntu/Linux health and incident triage report
#
# Usage:        sudo ./healthcheck.sh [-o FILE] [--cert HOST:PORT ...] [--no-network]
# Requirements: bash 4+, GNU coreutils/procps; optional: systemd, iproute2, openssl,
#               docker, zfsutils, smartmontools, chrony. Run --help for details.

set -uo pipefail
umask 077

VERSION="1.0.0"

# --- Configuration (override via environment) ---------------------------------
# Hostname used for the outbound DNS resolution test.
HC_DNS_TEST_HOST="${HC_DNS_TEST_HOST:-ubuntu.com}"
# IP address used for the outbound ICMP reachability test.
HC_PING_TARGET="${HC_PING_TARGET:-1.1.1.1}"
# -----------------------------------------------------------------------------

OUTPUT=""
NO_NETWORK=0
WARNINGS=0
declare -a CERT_TARGETS=()

usage() {
  cat <<'EOF'
Usage: healthcheck.sh [OPTIONS]

Create a timestamped, read-only Linux health report. Running as root provides
more complete journal, firewall, disk-health, and container information.

Options:
  -o, --output FILE       Write to FILE (default: ./healthcheck-HOST-TIME.txt)
      --cert HOST:PORT    Check a remote TLS certificate (repeatable)
      --no-network        Skip outbound DNS and connectivity tests
  -h, --help              Show this help
      --version           Show version

Exit codes: 0 report completed; 1 report completed with warnings;
            2 invalid usage; 3 report could not be created.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

while (($#)); do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
    --cert) [[ $# -ge 2 && $2 == *:* ]] || { echo "--cert requires HOST:PORT" >&2; exit 2; }; CERT_TARGETS+=("$2"); shift 2 ;;
    --no-network) NO_NETWORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "healthcheck.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)
safe_host=${host//[^A-Za-z0-9._-]/_}
stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $OUTPUT ]] || OUTPUT="./healthcheck-${safe_host}-${stamp}.txt"
if ! : >"$OUTPUT" 2>/dev/null; then
  echo "Cannot create report: $OUTPUT" >&2
  exit 3
fi

section() { printf '\n==== %s ====\n' "$1"; }
run() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@" 2>&1 || printf '[command exited %s]\n' "$?"
}
note_missing() { printf 'SKIPPED: %s is not installed.\n' "$1"; }

collect() {
  echo "Linux health report"
  echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date)"
  echo "Host: $host"
  echo "Collector version: $VERSION"
  echo "Privileges: $([[ ${EUID:-$(id -u)} -eq 0 ]] && echo root || echo unprivileged)"
  echo "NOTICE: This collector is read-only. Review the report before sharing;"
  echo "        process arguments, logs, addresses, and hostnames may be sensitive."

  section "Identity, OS, kernel, uptime"
  run hostnamectl
  [[ -r /etc/os-release ]] && run sed -n '1,20p' /etc/os-release
  run uname -a
  run uptime
  have who && run who -b

  section "CPU, memory, and load"
  have lscpu && run lscpu
  run free -h
  run cat /proc/loadavg
  echo "Top processes by CPU:"
  ps -eo pid,ppid,user,stat,%cpu,%mem,etime,comm,args --sort=-%cpu 2>&1 | head -n 26
  echo "Top processes by memory:"
  ps -eo pid,ppid,user,stat,%cpu,%mem,etime,comm,args --sort=-%mem 2>&1 | head -n 26

  section "Filesystems and storage"
  run df -hT
  run df -ih
  run findmnt
  have lsblk && run lsblk -e7 -o NAME,TYPE,SIZE,FSTYPE,FSVER,MOUNTPOINTS,ROTA,MODEL,SERIAL
  while read -r pct mountpoint; do
    pct=${pct%%%}
    if [[ $pct =~ ^[0-9]+$ ]] && ((pct >= 90)); then
      echo "WARNING: filesystem $mountpoint is ${pct}% full"
      WARNINGS=$((WARNINGS + 1))
    fi
  done < <(df -P --output=pcent,target 2>/dev/null | tail -n +2)

  section "systemd and recent critical events"
  if have systemctl; then
    run systemctl --failed --no-pager
    run systemctl is-system-running
    failed_count=$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')
    [[ $failed_count =~ ^[0-9]+$ ]] && ((failed_count > 0)) && WARNINGS=$((WARNINGS + 1))
  else
    note_missing systemctl
  fi
  if have journalctl; then
    run journalctl -p 0..3 --since "24 hours ago" --no-pager -n 300
    run journalctl -k --since "24 hours ago" --no-pager -g 'oom|out of memory|killed process|i/o error|segfault|hardware error|call trace'
  else
    note_missing journalctl
  fi

  section "Network configuration"
  have ip && run ip -brief address
  have ip && run ip route show table all
  have ip && run ip -6 route show table all
  if have resolvectl; then run resolvectl status; elif [[ -r /etc/resolv.conf ]]; then run cat /etc/resolv.conf; fi
  if have ss; then
    run ss -lntup
    run ss -s
  else
    note_missing ss
  fi
  if ((NO_NETWORK == 0)); then
    if have getent; then run getent ahosts "$HC_DNS_TEST_HOST"; else note_missing getent; fi
    if have ping; then run ping -c 2 -W 2 "$HC_PING_TARGET"; else note_missing ping; fi
  else
    echo "Outbound network tests skipped by request."
  fi

  section "Firewall"
  if have ufw; then run ufw status verbose; fi
  if have nft; then run nft list ruleset; elif have iptables; then run iptables -S; else note_missing "ufw/nft/iptables"; fi

  section "Time synchronization"
  if have timedatectl; then run timedatectl status; else run date --iso-8601=seconds; fi
  have chronyc && run chronyc tracking

  section "Updates and reboot state"
  if have apt-get; then
    run apt-get -s -o Debug::NoLocking=1 upgrade
    [[ -e /var/run/reboot-required ]] && run cat /var/run/reboot-required || echo "No reboot-required marker present."
  else
    note_missing apt-get
  fi

  section "Recent boots and shutdowns"
  have last && run last -x -n 30
  have journalctl && run journalctl --list-boots --no-pager

  section "Containers and virtualization"
  have systemd-detect-virt && run systemd-detect-virt
  if have docker; then
    run docker version
    run docker info
    run docker ps -a --no-trunc
  else
    echo "Docker not detected."
  fi
  if have pct; then run pct list; fi
  if have lxc-ls; then run lxc-ls --fancy; fi

  section "Disk and pool health"
  if have zpool; then run zpool status -xv; else echo "ZFS tools not detected."; fi
  if have smartctl; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]] && have lsblk; then
      while IFS= read -r disk; do
        [[ -n $disk ]] && run smartctl -H "$disk"
      done < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')
    else
      echo "SMART checks require root and lsblk."
    fi
  else
    note_missing smartctl
  fi

  section "Configured certificate checks"
  if ((${#CERT_TARGETS[@]} == 0)); then
    echo "No targets supplied. Add repeatable --cert HOST:PORT options."
  elif ! have openssl; then
    note_missing openssl
    WARNINGS=$((WARNINGS + 1))
  else
    for target in "${CERT_TARGETS[@]}"; do
      cert_host=${target%:*}; cert_port=${target##*:}
      echo "Target: $target"
      if cert=$(printf '' | openssl s_client -connect "${cert_host}:${cert_port}" -servername "$cert_host" 2>/dev/null | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256 2>&1); then
        printf '%s\n' "$cert"
      else
        echo "WARNING: TLS certificate retrieval failed"
        WARNINGS=$((WARNINGS + 1))
      fi
    done
  fi

  section "Dependency summary"
  for cmd in hostnamectl lscpu systemctl journalctl ip ss resolvectl ufw nft timedatectl apt-get docker zpool smartctl openssl; do
    printf '%-18s %s\n' "$cmd" "$(have "$cmd" && echo available || echo missing)"
  done

  section "Result"
  if ((WARNINGS)); then echo "COMPLETED WITH $WARNINGS WARNING(S)"; else echo "COMPLETED"; fi
}

collect >"$OUTPUT" 2>&1
printf 'Report written to: %s\n' "$OUTPUT"
((WARNINGS == 0)) || exit 1
exit 0
