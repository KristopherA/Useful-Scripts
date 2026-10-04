#!/usr/bin/env bash
# pve-preflight.sh - read-only Proxmox VE maintenance readiness assessment
#
# Usage:        sudo ./pve-preflight.sh [-o FILE] [--backup-hours N] [--warn-disk P] [--fail-disk P]
# Requirements: run as root on a Proxmox VE node (pveversion, pvecm, pvesm, ha-manager).

set -uo pipefail
umask 077

VERSION="1.0.0"
OUTPUT=""
BACKUP_HOURS=36
WARN_DISK=80
FAIL_DISK=90
WARN=0
FAIL=0

usage() {
  cat <<'EOF'
Usage: pve-preflight.sh [OPTIONS]

Options:
  -o, --output FILE         Save full evidence report to FILE
      --backup-hours N      Maximum acceptable backup age (default: 36)
      --warn-disk PERCENT   Disk warning threshold (default: 80)
      --fail-disk PERCENT   Disk failure threshold (default: 90)
  -h, --help                Show help
      --version             Show version

This script is read-only. It does not migrate guests, start backups, change HA,
or modify cluster/Ceph/storage configuration. Run as root on a Proxmox VE node.

Exit codes: 0 READY; 1 READY WITH WARNINGS; 2 DO NOT PROCEED;
            3 unsupported host, insufficient privilege, or usage error.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n==== %s ====\n' "$1"; }
evidence() { printf '$'; printf ' %q' "$@"; printf '\n'; "$@" 2>&1 || printf '[command exited %s]\n' "$?"; }
pass() { printf '%-32s PASS     %s\n' "$1" "${2:-}"; }
warning() { printf '%-32s WARNING  %s\n' "$1" "$2"; WARN=$((WARN + 1)); }
failure() { printf '%-32s FAIL     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

while (($#)); do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || { usage >&2; exit 3; }; OUTPUT=$2; shift 2 ;;
    --backup-hours) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 3; }; BACKUP_HOURS=$2; shift 2 ;;
    --warn-disk) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { usage >&2; exit 3; }; WARN_DISK=$2; shift 2 ;;
    --fail-disk) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { usage >&2; exit 3; }; FAIL_DISK=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "pve-preflight.sh $VERSION"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 3 ;;
  esac
done
((WARN_DISK < FAIL_DISK && FAIL_DISK <= 100)) || { echo "Disk thresholds must satisfy warn < fail <= 100" >&2; exit 3; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run this preflight as root." >&2; exit 3; }
have pveversion || { echo "This does not appear to be a Proxmox VE node (pveversion missing)." >&2; exit 3; }

host=$(hostname -s 2>/dev/null || echo unknown)
stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $OUTPUT ]] || OUTPUT="./pve-preflight-${host//[^A-Za-z0-9._-]/_}-${stamp}.txt"
if ! : >"$OUTPUT" 2>/dev/null; then echo "Cannot create report: $OUTPUT" >&2; exit 3; fi

collect() {
  echo "PROXMOX VE MAINTENANCE READINESS"
  echo "================================"
  echo "Generated: $(date --iso-8601=seconds)"
  echo "Node: $host"
  echo "Version: $(pveversion 2>/dev/null | head -n1)"
  echo "Policy: backup <= ${BACKUP_HOURS}h; disk warning >= ${WARN_DISK}%; failure >= ${FAIL_DISK}%"
  echo

  # Cluster and quorum. A deliberately standalone node is accepted with a warning.
  if have pvecm; then
    cluster_status=$(pvecm status 2>&1 || true)
    if grep -q 'Quorate:[[:space:]]*Yes' <<<"$cluster_status"; then pass "Cluster quorum"
    elif grep -qiE 'not (a |)cluster member|cannot initialize CMAP' <<<"$cluster_status"; then warning "Cluster quorum" "standalone/non-clustered node"
    else failure "Cluster quorum" "not quorate or status unavailable"; fi
  else
    failure "Cluster quorum" "pvecm unavailable"
    cluster_status="pvecm unavailable"
  fi

  # HA status is required only when HA resources are configured.
  if have ha-manager; then
    ha_status=$(ha-manager status 2>&1 || true)
    if grep -qiE 'error|fence|unknown|stopped' <<<"$ha_status"; then failure "HA status" "error/fence/unknown/stopped state detected"
    else pass "HA status"; fi
  else
    warning "HA status" "ha-manager unavailable"
    ha_status="ha-manager unavailable"
  fi

  # Ceph is assessed only when configured.
  if have ceph && { [[ -e /etc/pve/ceph.conf ]] || [[ -e /etc/ceph/ceph.conf ]]; }; then
    ceph_health=$(ceph health 2>&1 || true)
    case "$ceph_health" in
      HEALTH_OK*) pass "Ceph health" "$ceph_health" ;;
      HEALTH_WARN*) warning "Ceph health" "$ceph_health" ;;
      *) failure "Ceph health" "$ceph_health" ;;
    esac
  else
    pass "Ceph health" "not configured"
    ceph_health="not configured"
  fi

  # Proxmox storage status includes PBS reachability where PBS storage is configured.
  if have pvesm; then
    storage_status=$(pvesm status 2>&1 || true)
    if awk 'NR>1 && $3 !~ /^active$/ {bad=1} END{exit !bad}' <<<"$storage_status"; then
      failure "Configured storage" "one or more storage targets inactive"
    elif grep -qE '^Name[[:space:]]' <<<"$storage_status"; then pass "Configured storage"
    else failure "Configured storage" "could not read storage status"; fi
    if awk 'NR>1 && $2=="pbs" {found=1; if ($3!="active") bad=1} END{exit !(found && bad)}' <<<"$storage_status"; then
      failure "PBS reachability" "configured PBS storage inactive"
    elif awk 'NR>1 && $2=="pbs" {found=1} END{exit !found}' <<<"$storage_status"; then pass "PBS reachability"
    else pass "PBS reachability" "not configured"; fi
  else
    failure "Configured storage" "pvesm unavailable"
    storage_status="pvesm unavailable"
  fi

  # Recent successful vzdump task. This validates task outcome, independent of storage type.
  cutoff=$(( $(date +%s) - BACKUP_HOURS * 3600 ))
  recent_backup=0
  if [[ -d /var/log/pve/tasks ]]; then
    while IFS= read -r tasklog; do
      if grep -qE 'TASK OK|status:.*OK' "$tasklog" 2>/dev/null && grep -qiE 'vzdump|backup' "$tasklog" 2>/dev/null; then recent_backup=1; break; fi
    done < <(find /var/log/pve/tasks -type f -newermt "@$cutoff" -print 2>/dev/null)
  fi
  if ((recent_backup)); then pass "Recent successful backup" "within ${BACKUP_HOURS}h"
  else warning "Recent successful backup" "none proven from local task logs within ${BACKUP_HOURS}h"; fi

  disk_detail=$(df -P / /var/lib/vz /boot 2>/dev/null | awk 'NR==1 || !seen[$6]++')
  disk_worst=$(awk 'NR>1 {gsub(/%/,"",$5); if ($5>m)m=$5} END{print m+0}' <<<"$disk_detail")
  if ((disk_worst >= FAIL_DISK)); then failure "Local disk space" "highest utilization ${disk_worst}%"
  elif ((disk_worst >= WARN_DISK)); then warning "Local disk space" "highest utilization ${disk_worst}%"
  else pass "Local disk space" "highest utilization ${disk_worst}%"; fi

  if have zpool && zpool list -H >/dev/null 2>&1; then
    zfs_health=$(zpool status -x 2>&1 || true)
    if grep -q 'all pools are healthy' <<<"$zfs_health"; then pass "ZFS health"
    else failure "ZFS health" "pool reports a problem"; fi
  else
    pass "ZFS health" "no imported pools"
    zfs_health="no imported pools"
  fi

  if have systemctl; then
    failed_units=$(systemctl --failed --no-legend 2>/dev/null | sed '/^[[:space:]]*$/d')
    if [[ -n $failed_units ]]; then failure "Failed systemd units" "one or more units failed"; else pass "Failed systemd units"; fi
  else
    failure "Failed systemd units" "systemctl unavailable"
    failed_units="systemctl unavailable"
  fi

  # Pending replication jobs and stopped guests should be reviewed, but are not universally unsafe.
  if have pvesr; then
    replication=$(pvesr status 2>&1 || true)
    if grep -qiE 'error|fail' <<<"$replication"; then warning "Replication status" "error/failure text detected"; else pass "Replication status"; fi
  else replication="pvesr unavailable"; fi

  section "Evidence: cluster"
  printf '%s\n' "$cluster_status"
  section "Evidence: HA"
  printf '%s\n' "$ha_status"
  section "Evidence: Ceph"
  printf '%s\n' "$ceph_health"
  have ceph && evidence ceph status
  section "Evidence: storage and disk"
  printf '%s\n' "$storage_status"
  printf '%s\n' "$disk_detail"
  have zpool && printf '%s\n' "$zfs_health"
  section "Evidence: guests"
  have qm && evidence qm list
  have pct && evidence pct list
  section "Evidence: replication"
  printf '%s\n' "$replication"
  section "Evidence: failed units"
  printf '%s\n' "${failed_units:-none}"
  section "Evidence: package/reboot state"
  [[ -e /var/run/reboot-required ]] && evidence cat /var/run/reboot-required || echo "No reboot-required marker present."
  have apt-get && evidence apt-get -s -o Debug::NoLocking=1 upgrade

  section "RESULT"
  if ((FAIL > 0)); then
    echo "DO NOT PROCEED"
    echo "$FAIL blocking failure(s), $WARN warning(s)."
  elif ((WARN > 0)); then
    echo "READY WITH CAUTION"
    echo "$WARN warning(s) require operator review."
  else
    echo "READY"
  fi
  echo "This preflight cannot know application-level maintenance constraints;"
  echo "confirm migrations, backup restorability, change approval, and console access."
}

collect >"$OUTPUT" 2>&1
echo "Report written to: $OUTPUT"
((FAIL == 0)) || exit 2
((WARN == 0)) || exit 1
exit 0
