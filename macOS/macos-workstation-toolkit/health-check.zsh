#!/bin/zsh

# Read-only macOS workstation health check.
# Designed for macOS Monterey 12 and later. No administrator access required.

emulate -L zsh
setopt pipefail
umask 077

SCRIPT_VERSION="1.0.0"
FULL_CHECK=0
OUTPUT_FILE=""
PASS_COUNT=0
WARN_COUNT=0
INFO_COUNT=0

usage() {
  cat <<'EOF'
Usage: health-check.zsh [--full] [--output FILE]

  --full         Also test DNS/internet access and scan for macOS updates.
                 The update scan can take several minutes.
  --output FILE  Save a copy of the report while also displaying it.
  -h, --help     Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --full) FULL_CHECK=1 ;;
    --output)
      shift
      [[ $# -gt 0 ]] || { print -u2 "Missing value for --output"; exit 64; }
      OUTPUT_FILE="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 64 ;;
  esac
  shift
done

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p -- "${OUTPUT_FILE:h}" || exit 73
  exec > >(tee "$OUTPUT_FILE") 2>&1
fi

result() {
  local level="$1" label="$2" detail="$3"
  case "$level" in
    PASS) (( PASS_COUNT++ )) ;;
    WARN) (( WARN_COUNT++ )) ;;
    INFO) (( INFO_COUNT++ )) ;;
  esac
  printf '[%-4s] %-24s %s\n' "$level" "$label" "$detail"
}

command_output() {
  "$@" 2>&1
}

print "macOS Workstation Health Check v${SCRIPT_VERSION}"
print "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print -r -- "------------------------------------------------------------"

os_version=$(sw_vers -productVersion 2>/dev/null || print "unknown")
os_build=$(sw_vers -buildVersion 2>/dev/null || print "unknown")
arch=$(uname -m 2>/dev/null || print "unknown")
result INFO "Operating system" "macOS ${os_version} (${os_build}), ${arch}"
result INFO "Uptime" "$(uptime | sed -E 's/^[[:space:]]+//')"

disk_stats=$(df -Pk / 2>/dev/null | awk 'NR == 2 { printf "%s %s %d", $2, $4, ($4 * 100 / $2) }')
if [[ -n "$disk_stats" ]]; then
  read -r disk_total_kb disk_free_kb disk_free_pct <<< "$disk_stats"
  disk_free_gb=$(( disk_free_kb / 1024 / 1024 ))
  if (( disk_free_gb < 5 || disk_free_pct < 5 )); then
    result WARN "Startup disk" "Only ${disk_free_gb} GB (${disk_free_pct}%) free; immediate cleanup recommended"
  elif (( disk_free_gb < 20 || disk_free_pct < 10 )); then
    result WARN "Startup disk" "${disk_free_gb} GB (${disk_free_pct}%) free; plan cleanup"
  else
    result PASS "Startup disk" "${disk_free_gb} GB (${disk_free_pct}%) free"
  fi
else
  result WARN "Startup disk" "Unable to read disk capacity"
fi

memory_summary=$(memory_pressure -Q 2>/dev/null | tail -1)
if [[ -n "$memory_summary" ]]; then
  memory_pct=$(print -r -- "$memory_summary" | awk -F: '{gsub(/[^0-9]/, "", $2); print $2}')
  if [[ "$memory_pct" == <-> ]] && (( memory_pct < 10 )); then
    result WARN "Memory" "$memory_summary"
  else
    result PASS "Memory" "$memory_summary"
  fi
else
  page_size=$(vm_stat 2>/dev/null | awk 'NR == 1 {gsub(/[^0-9]/, "", $8); print $8}')
  [[ -n "$page_size" ]] && result INFO "Memory" "vm_stat available; live pressure percentage unavailable"
fi

battery_text=$(pmset -g batt 2>/dev/null)
if print -r -- "$battery_text" | grep -q "InternalBattery"; then
  battery_line=$(print -r -- "$battery_text" | tail -1 | sed -E 's/^[[:space:]]+//')
  battery_condition=$(system_profiler SPPowerDataType 2>/dev/null | awk -F: '/Condition:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
  if [[ -n "$battery_condition" && "$battery_condition" != "Normal" ]]; then
    result WARN "Battery" "${battery_line}; condition: ${battery_condition}"
  else
    result PASS "Battery" "${battery_line}${battery_condition:+; condition: ${battery_condition}}"
  fi
else
  result INFO "Battery" "No internal battery detected"
fi

fv_status=$(command_output fdesetup status)
if [[ "$fv_status" == *"FileVault is On"* ]]; then
  result PASS "FileVault" "Enabled"
elif [[ "$fv_status" == *"FileVault is Off"* ]]; then
  result WARN "FileVault" "Disabled"
else
  result INFO "FileVault" "Status unavailable without additional access"
fi

firewall_status=$(command_output /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)
if [[ "$firewall_status" == *"enabled"* ]]; then
  result PASS "Firewall" "Enabled"
elif [[ "$firewall_status" == *"disabled"* ]]; then
  result WARN "Firewall" "Disabled"
else
  result INFO "Firewall" "Status unavailable"
fi

gatekeeper_status=$(command_output spctl --status)
if [[ "$gatekeeper_status" == *"assessments enabled"* ]]; then
  result PASS "Gatekeeper" "Enabled"
else
  result WARN "Gatekeeper" "$gatekeeper_status"
fi

sip_status=$(command_output csrutil status)
if [[ "$sip_status" == *"System Integrity Protection status: enabled"* ]]; then
  result PASS "System Integrity" "SIP enabled"
else
  result WARN "System Integrity" "$sip_status"
fi

mdm_status=$(command_output profiles status -type enrollment)
if [[ "$mdm_status" == *"MDM enrollment: Yes"* ]]; then
  result PASS "Device management" "MDM enrolled"
else
  result INFO "Device management" "Not MDM enrolled, or status unavailable"
fi

if route -n get default >/dev/null 2>&1; then
  result PASS "Network route" "A default route is available"
else
  result WARN "Network route" "No default route detected"
fi

update_schedule=$(command_output softwareupdate --schedule)
if [[ "$update_schedule" == *" on"* ]]; then
  result PASS "Update checks" "$update_schedule"
else
  result WARN "Update checks" "$update_schedule"
fi

if (( FULL_CHECK )); then
  if dscacheutil -q host -a name apple.com 2>/dev/null | grep -q '^ip_address:'; then
    result PASS "DNS" "apple.com resolved"
  else
    result WARN "DNS" "Unable to resolve apple.com"
  fi

  if nc -G 5 -z apple.com 443 >/dev/null 2>&1; then
    result PASS "Internet" "HTTPS connectivity available"
  else
    result WARN "Internet" "Could not connect to apple.com on TCP 443"
  fi

  print "Scanning for macOS updates (this may take several minutes)..."
  update_output=$(softwareupdate --list 2>&1)
  update_rc=$?
  if (( update_rc != 0 )); then
    result WARN "Available updates" "Scan failed: $(print -r -- "$update_output" | tail -1)"
  elif [[ "$update_output" == *"No new software available"* ]]; then
    result PASS "Available updates" "No new software updates reported"
  else
    result WARN "Available updates" "One or more updates may be available; review Software Update"
  fi
fi

print -r -- "------------------------------------------------------------"
print "Summary: ${PASS_COUNT} passed, ${WARN_COUNT} need attention, ${INFO_COUNT} informational"
(( WARN_COUNT == 0 ))
