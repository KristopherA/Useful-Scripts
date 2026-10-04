#!/usr/bin/env bash
# what-changed.sh - read-only Linux change and incident timeline collector
#
# Usage:        sudo ./what-changed.sh [--since "24 hours ago"] [-o FILE] [--max-files N]
# Requirements: bash 4+, GNU date/find; optional: journalctl, auditd (ausearch), docker.

set -uo pipefail
umask 077

VERSION="1.0.0"
SINCE="24 hours ago"
OUTPUT=""
MAX_FILES=1000
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: what-changed.sh [OPTIONS]

Options:
      --since DATE       Beginning of timeline (default: "24 hours ago")
  -o, --output FILE      Output file (default: ./what-changed-HOST-TIME.txt)
      --max-files N      Limit modified-file listings (default: 1000)
  -h, --help             Show help
      --version          Show version

Examples:
  sudo what-changed.sh --since "2 days ago"
  what-changed.sh --since "2026-09-13 08:00" -o incident-timeline.txt

The script only reads state and logs. Root is recommended for complete results.
Exit codes: 0 completed; 1 completed with permission/data warnings;
            2 invalid usage; 3 report creation failed.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n==== %s ====\n' "$1"; }
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@" 2>&1 || printf '[command exited %s]\n' "$?"; }

while (($#)); do
  case "$1" in
    --since) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SINCE=$2; shift 2 ;;
    -o|--output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
    --max-files) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --max-files" >&2; exit 2; }; MAX_FILES=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "what-changed.sh $VERSION"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! since_epoch=$(date -d "$SINCE" +%s 2>/dev/null); then
  echo "Invalid --since value for GNU date: $SINCE" >&2
  exit 2
fi
if ((since_epoch > $(date +%s))); then echo "--since cannot be in the future" >&2; exit 2; fi

host=$(hostname -s 2>/dev/null || echo unknown)
stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $OUTPUT ]] || OUTPUT="./what-changed-${host//[^A-Za-z0-9._-]/_}-${stamp}.txt"
if ! : >"$OUTPUT" 2>/dev/null; then echo "Cannot create report: $OUTPUT" >&2; exit 3; fi

journal() {
  if have journalctl; then journalctl --since "$SINCE" --no-pager "$@" 2>&1 || true
  else echo "SKIPPED: journalctl is unavailable"; WARNINGS=$((WARNINGS + 1)); fi
}

collect() {
  echo "Linux change timeline"
  echo "Generated: $(date --iso-8601=seconds)"
  echo "Host: $host"
  echo "Since: $SINCE ($(date -d "@$since_epoch" --iso-8601=seconds))"
  echo "Privileges: $([[ ${EUID:-$(id -u)} -eq 0 ]] && echo root || echo unprivileged)"
  echo "NOTICE: Read-only. Output may include usernames, IP addresses, command lines,"
  echo "        and configuration paths; review before sharing."
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "WARNING: Run as root for complete auth, audit, journal, and file metadata."
    WARNINGS=$((WARNINGS + 1))
  fi

  section "APT and dpkg activity"
  if [[ -d /var/log/apt ]]; then
    while IFS= read -r log; do
      echo "--- $log"
      case "$log" in *.gz) have zgrep && zgrep -hE '^(Start-Date|End-Date|Commandline|Install:|Upgrade:|Remove:|Purge:)' "$log" || true ;;
        *) grep -hE '^(Start-Date|End-Date|Commandline|Install:|Upgrade:|Remove:|Purge:)' "$log" 2>/dev/null || true ;;
      esac
    done < <(find /var/log/apt -maxdepth 1 -type f -newermt "$SINCE" -print 2>/dev/null | sort)
  else
    echo "APT logs not found."
  fi
  [[ -r /var/log/dpkg.log ]] && awk -v cutoff="$(date -d "@$since_epoch" '+%Y-%m-%d %H:%M:%S')" '$1" "$2 >= cutoff' /var/log/dpkg.log 2>/dev/null | tail -n 1000

  section "Modified configuration and certificate files"
  echo "Files under /etc modified since the requested time (limit: $MAX_FILES):"
  find /etc -xdev -type f -newermt "$SINCE" -printf '%TY-%Tm-%TdT%TH:%TM:%TS %u:%g %m %p\n' 2>/dev/null | sort | head -n "$MAX_FILES"
  for dir in /etc/ssl /etc/letsencrypt /var/lib/acme; do
    [[ -d $dir ]] || continue
    echo "Certificate-related changes under $dir:"
    find "$dir" -xdev -type f -newermt "$SINCE" -printf '%TY-%Tm-%TdT%TH:%TM:%TS %u:%g %m %p\n' 2>/dev/null | sort | head -n "$MAX_FILES"
  done

  section "Users, groups, authentication, sudo, and SSH"
  for f in /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/sudoers; do
    [[ -e $f ]] && stat -c '%y %U:%G %a %n' "$f" 2>/dev/null
  done
  journal _COMM=useradd
  journal _COMM=usermod
  journal _COMM=userdel
  journal _COMM=groupadd
  journal -t sudo
  journal -u ssh -u sshd
  if have last; then run last -Faiwx -n 100; fi

  section "Service starts, stops, restarts, enablement, and failures"
  journal -u systemd -g 'Started|Stopped|Stopping|Starting|Reloaded|Failed|enabled|disabled'
  journal -p 0..3
  if have systemctl; then run systemctl --failed --no-pager; fi

  section "Boots, shutdowns, and kernel changes"
  have journalctl && run journalctl --list-boots --no-pager
  have last && run last -x -n 50
  journal -k -g 'Linux version|Command line|oom|out of memory|I/O error|segfault|hardware error'
  uname -a

  section "Firewall and network changes"
  journal -g 'UFW|ufw|firewall|nftables|iptables|NetworkManager|systemd-networkd|netplan|link.*(up|down)'
  for dir in /etc/netplan /etc/systemd/network /etc/NetworkManager/system-connections /etc/ufw; do
    [[ -d $dir ]] || continue
    find "$dir" -xdev -type f -newermt "$SINCE" -printf '%TY-%Tm-%TdT%TH:%TM:%TS %u:%g %m %p\n' 2>/dev/null | sort
  done

  section "Cron jobs and systemd timers"
  for dir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/systemd/system; do
    [[ -d $dir ]] || continue
    find "$dir" -xdev -type f -newermt "$SINCE" -printf '%TY-%Tm-%TdT%TH:%TM:%TS %u:%g %m %p\n' 2>/dev/null | sort | head -n "$MAX_FILES"
  done
  have systemctl && run systemctl list-timers --all --no-pager

  section "Docker changes"
  if have docker && docker info >/dev/null 2>&1; then
    run docker ps -a --no-trunc --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.CreatedAt}}\t{{.Status}}'
    run docker images --digests --no-trunc
    run docker events --since "$(date -d "@$since_epoch" --iso-8601=seconds)" --until "$(date --iso-8601=seconds)"
  else
    echo "Docker unavailable or not accessible."
  fi

  section "Audit subsystem"
  if have ausearch; then
    ausearch -ts "$(date -d "@$since_epoch" '+%m/%d/%Y %H:%M:%S')" -m CONFIG_CHANGE,USER_CHAUTHTOK,ADD_USER,DEL_USER,ADD_GROUP,DEL_GROUP,SERVICE_START,SERVICE_STOP 2>&1 || true
  else
    echo "SKIPPED: ausearch not installed (auditd provides stronger attribution)."
  fi

  section "Caveats and result"
  echo "This is an evidence timeline, not proof of causation. Linux does not retain"
  echo "complete file-change history unless auditing/version control was configured."
  ((WARNINGS == 0)) && echo "COMPLETED" || echo "COMPLETED WITH $WARNINGS WARNING(S)"
}

collect >"$OUTPUT" 2>&1
echo "Report written to: $OUTPUT"
((WARNINGS == 0)) || exit 1
exit 0
