#!/usr/bin/env bash
# patch-check.sh - read-only Ubuntu/Debian patch and reboot readiness assessment
#
# Usage:        sudo ./patch-check.sh [-o FILE] [--backup-marker PATH] [--backup-hours N]
# Requirements: Debian/Ubuntu with apt-get/apt-mark; optional: needrestart, systemd.

set -uo pipefail
umask 077

SCRIPT_VERSION="1.0.0"
OUTPUT=""
MIN_ROOT_MB=2048
MIN_BOOT_MB=512
BACKUP_MARKER=""
BACKUP_HOURS=36
WARN=0
FAIL=0

usage() {
  cat <<'EOF'
Usage: patch-check.sh [OPTIONS]

Options:
  -o, --output FILE          Save detailed report to FILE
      --min-root-mb N        Required free space on / (default: 2048)
      --min-boot-mb N        Required free space on /boot (default: 512)
      --backup-marker PATH   File whose modification time proves a recent backup
      --backup-hours N       Maximum backup marker age (default: 36)
  -h, --help                 Show help
      --version              Show version

The script does not refresh package lists, install packages, reboot, or restart
services. For current results, run your approved `apt-get update` process first.

Exit codes: 0 READY; 1 READY WITH CAUTION; 2 NOT READY;
            3 unsupported host, insufficient data, or usage error.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n==== %s ====\n' "$1"; }
pass() { printf '%-32s PASS     %s\n' "$1" "${2:-}"; }
warning() { printf '%-32s WARNING  %s\n' "$1" "$2"; WARN=$((WARN + 1)); }
failure() { printf '%-32s FAIL     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

while (($#)); do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || { usage >&2; exit 3; }; OUTPUT=$2; shift 2 ;;
    --min-root-mb) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { usage >&2; exit 3; }; MIN_ROOT_MB=$2; shift 2 ;;
    --min-boot-mb) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { usage >&2; exit 3; }; MIN_BOOT_MB=$2; shift 2 ;;
    --backup-marker) [[ $# -ge 2 ]] || { usage >&2; exit 3; }; BACKUP_MARKER=$2; shift 2 ;;
    --backup-hours) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 3; }; BACKUP_HOURS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "patch-check.sh $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 3 ;;
  esac
done

have apt-get || { echo "apt-get is required; this script supports Debian/Ubuntu family systems." >&2; exit 3; }
[[ -r /etc/os-release ]] || { echo "/etc/os-release is unavailable" >&2; exit 3; }

host=$(hostname -s 2>/dev/null || echo unknown)
stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $OUTPUT ]] || OUTPUT="./patch-check-${host//[^A-Za-z0-9._-]/_}-${stamp}.txt"
if ! : >"$OUTPUT" 2>/dev/null; then echo "Cannot create report: $OUTPUT" >&2; exit 3; fi

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT HUP INT TERM
simulation="$tmpdir/apt-simulation.txt"
if ! apt-get -s -o Debug::NoLocking=1 dist-upgrade >"$simulation" 2>&1; then
  echo "APT simulation failed; package state may be broken. See report." >&2
  # Continue so the report contains useful evidence; readiness will fail.
  APT_SIM_OK=0
else
  APT_SIM_OK=1
fi

collect() {
  # Standard Linux OS metadata file, checked above.
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "PATCH AND REBOOT READINESS"
  echo "=========================="
  echo "Generated: $(date --iso-8601=seconds)"
  echo "Host: $host"
  echo "OS: ${PRETTY_NAME:-unknown}"
  echo "Kernel: $(uname -r)"
  echo "Collector version: $SCRIPT_VERSION"
  echo "NOTICE: Read-only assessment; APT package indexes are not refreshed."
  echo

  if ((APT_SIM_OK)); then pass "APT simulation"; else failure "APT simulation" "dist-upgrade simulation failed"; fi

  updates=$(grep -c '^Inst ' "$simulation" 2>/dev/null || true)
  security=$(grep '^Inst ' "$simulation" 2>/dev/null | grep -ciE 'security|UbuntuESMApps|UbuntuESMInfra' || true)
  kernel=$(grep '^Inst ' "$simulation" 2>/dev/null | grep -ciE 'linux-(image|headers|modules|generic|virtual|azure|aws|gcp|oem)|proxmox-kernel|pve-kernel' || true)
  removals=$(grep -c '^Remv ' "$simulation" 2>/dev/null || true)
  held=$(apt-mark showhold 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  printf '%-32s %s\n' "Updates available" "$updates"
  printf '%-32s %s\n' "Security updates (estimated)" "$security"
  printf '%-32s %s\n' "Kernel-related updates" "$kernel"
  printf '%-32s %s\n' "Planned package removals" "$removals"
  printf '%-32s %s\n' "Held packages" "$held"
  if ((removals == 0)); then pass "Package removals"; else failure "Package removals" "$removals removal(s) proposed; review required"; fi
  if ((held == 0)); then pass "Held packages"; else warning "Held packages" "$held held package(s) may remain unpatched"; fi

  lists_age="unknown"
  if [[ -d /var/lib/apt/lists ]]; then
    newest_list=$(find /var/lib/apt/lists -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -n1)
    if [[ -n ${newest_list:-} ]]; then lists_age=$(( ( $(date +%s) - ${newest_list%.*} ) / 3600 )); fi
  fi
  if [[ $lists_age =~ ^[0-9]+$ && $lists_age -le 24 ]]; then pass "APT index freshness" "${lists_age}h old"
  elif [[ $lists_age =~ ^[0-9]+$ ]]; then warning "APT index freshness" "${lists_age}h old; refresh through approved process"
  else warning "APT index freshness" "could not determine"; fi

  if [[ -e /var/run/reboot-required ]]; then warning "Reboot currently required" "yes"; else pass "Reboot currently required" "no"; fi
  if [[ -r /var/run/reboot-required.pkgs ]]; then
    echo "Packages currently requesting reboot:"
    sed 's/^/  /' /var/run/reboot-required.pkgs
  fi

  restart_count="unknown"
  if have needrestart; then
    needrestart -b >"$tmpdir/needrestart.txt" 2>&1 || true
    restart_count=$(grep -c '^NEEDRESTART-SVC:' "$tmpdir/needrestart.txt" 2>/dev/null || true)
    printf '%-32s %s\n' "Services requiring restart" "$restart_count"
  else
    warning "Restart assessment" "needrestart not installed"
  fi

  root_free=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ $root_free =~ ^[0-9]+$ && $root_free -ge MIN_ROOT_MB ]]; then pass "Root free space" "${root_free} MiB"
  else failure "Root free space" "${root_free:-unknown} MiB; require ${MIN_ROOT_MB} MiB"; fi
  if mountpoint -q /boot 2>/dev/null; then
    boot_free=$(df -Pm /boot 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ $boot_free =~ ^[0-9]+$ && $boot_free -ge MIN_BOOT_MB ]]; then pass "Boot free space" "${boot_free} MiB on /boot"
    else failure "Boot free space" "${boot_free:-unknown} MiB on /boot; require ${MIN_BOOT_MB} MiB"; fi
  else
    pass "Boot free space" "/boot shares root filesystem"
  fi

  if [[ -n $BACKUP_MARKER ]]; then
    if [[ -e $BACKUP_MARKER ]]; then
      marker_epoch=$(stat -c %Y "$BACKUP_MARKER" 2>/dev/null || echo 0)
      marker_age=$(( ( $(date +%s) - marker_epoch ) / 3600 ))
      if ((marker_epoch > 0 && marker_age <= BACKUP_HOURS)); then pass "Recent backup marker" "${marker_age}h old"
      else failure "Recent backup marker" "${marker_age}h old; maximum ${BACKUP_HOURS}h"; fi
    else
      failure "Recent backup marker" "not found: $BACKUP_MARKER"
    fi
  else
    warning "Recent backup" "not assessed; use --backup-marker PATH"
  fi

  mysql=no; docker=no; proxmox=no
  { have mysql || { have systemctl && systemctl list-unit-files 'mysql*.service' 'mariadb*.service' 2>/dev/null | grep -q service; }; } && mysql=yes
  { have docker || [[ -S /var/run/docker.sock ]]; } && docker=yes
  have pveversion && proxmox=yes
  printf '%-32s %s\n' "MySQL/MariaDB detected" "$mysql"
  printf '%-32s %s\n' "Docker detected" "$docker"
  printf '%-32s %s\n' "Proxmox detected" "$proxmox"
  [[ $proxmox == no ]] || warning "Proxmox coordination" "run pve-preflight.sh and follow cluster procedure"
  if have systemctl; then
    failed_units=$(systemctl --failed --no-legend 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if ((failed_units == 0)); then pass "Failed systemd units"; else failure "Failed systemd units" "$failed_units unit(s) failed"; fi
  fi

  section "APT simulation evidence"
  cat "$simulation"
  section "Held packages"
  apt-mark showhold 2>&1 || true
  section "Disk evidence"
  df -hT / /boot /boot/efi 2>&1 | awk '!seen[$0]++'
  section "Restart evidence"
  [[ -f $tmpdir/needrestart.txt ]] && cat "$tmpdir/needrestart.txt" || echo "needrestart unavailable"
  section "Failed service evidence"
  have systemctl && systemctl --failed --no-pager 2>&1

  section "RESULT"
  if ((FAIL > 0)); then echo "NOT READY - $FAIL blocking issue(s), $WARN warning(s)."
  elif ((WARN > 0)); then echo "READY WITH CAUTION - $WARN warning(s) require review."
  else echo "READY"; fi
  echo "Before proceeding, confirm change approval, application drain/failover,"
  echo "recoverable backups, console access, and a tested rollback plan."
}

collect >"$OUTPUT" 2>&1
echo "Report written to: $OUTPUT"
((FAIL == 0)) || exit 2
((WARN == 0)) || exit 1
exit 0
