#!/bin/zsh

# Read-only macOS security posture audit.
# Findings are advisory and should be mapped to your organization's policy.

emulate -L zsh
setopt pipefail
umask 077

SCRIPT_VERSION="1.0.0"
CHECK_UPDATES=0
REQUIRE_MDM=0
OUTPUT_FILE=""
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0
INFO_COUNT=0

usage() {
  cat <<'EOF'
Usage: security-audit.zsh [options]

  --check-updates  Scan Apple Software Update. This can take several minutes.
  --require-mdm    Treat missing MDM enrollment as a failure.
  --output FILE    Save a copy of the report while displaying it.
  -h, --help       Show this help.

Exit codes: 0 = no findings, 1 = warnings/incomplete checks, 2 = failures.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --check-updates) CHECK_UPDATES=1 ;;
    --require-mdm) REQUIRE_MDM=1 ;;
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

finding() {
  local level="$1" control="$2" detail="$3"
  case "$level" in
    PASS) (( PASS_COUNT++ )) ;;
    WARN) (( WARN_COUNT++ )) ;;
    FAIL) (( FAIL_COUNT++ )) ;;
    UNKN) (( UNKNOWN_COUNT++ )) ;;
    INFO) (( INFO_COUNT++ )) ;;
  esac
  printf '[%-4s] %-25s %s\n' "$level" "$control" "$detail"
}

capture() { "$@" 2>&1; }

print "macOS Security Audit v${SCRIPT_VERSION}"
print "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print "Host details are intentionally limited to reduce sensitive output."
print -r -- "--------------------------------------------------------------------"

os_version=$(sw_vers -productVersion 2>/dev/null || print "unknown")
os_build=$(sw_vers -buildVersion 2>/dev/null || print "unknown")
finding INFO "Operating system" "macOS ${os_version} (${os_build})"

fv=$(capture fdesetup status)
if [[ "$fv" == *"FileVault is On"* ]]; then
  finding PASS "Disk encryption" "FileVault is enabled"
elif [[ "$fv" == *"FileVault is Off"* ]]; then
  finding FAIL "Disk encryption" "FileVault is disabled"
else
  finding UNKN "Disk encryption" "Unable to determine FileVault status"
fi

sip=$(capture csrutil status)
if [[ "$sip" == *"System Integrity Protection status: enabled"* ]]; then
  finding PASS "System Integrity" "SIP is enabled"
elif [[ "$sip" == *"disabled"* ]]; then
  finding FAIL "System Integrity" "SIP is disabled"
else
  finding UNKN "System Integrity" "$sip"
fi

gatekeeper=$(capture spctl --status)
if [[ "$gatekeeper" == *"assessments enabled"* ]]; then
  finding PASS "Gatekeeper" "App assessments are enabled"
elif [[ "$gatekeeper" == *"assessments disabled"* ]]; then
  finding FAIL "Gatekeeper" "App assessments are disabled"
else
  finding UNKN "Gatekeeper" "$gatekeeper"
fi

firewall=$(capture /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)
if [[ "$firewall" == *"enabled"* ]]; then
  finding PASS "Application firewall" "Enabled"
elif [[ "$firewall" == *"disabled"* ]]; then
  finding WARN "Application firewall" "Disabled; confirm this matches organizational policy"
else
  finding UNKN "Application firewall" "Unable to determine status"
fi

schedule=$(capture softwareupdate --schedule)
if [[ "$schedule" == *" on"* ]]; then
  finding PASS "Automatic update check" "$schedule"
elif [[ "$schedule" == *" off"* ]]; then
  finding WARN "Automatic update check" "$schedule"
else
  finding UNKN "Automatic update check" "$schedule"
fi

critical_updates=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall 2>/dev/null)
if [[ "$critical_updates" == "1" ]]; then
  finding PASS "Critical updates" "Automatic installation is explicitly enabled"
elif [[ "$critical_updates" == "0" ]]; then
  finding WARN "Critical updates" "Automatic installation is explicitly disabled"
else
  finding INFO "Critical updates" "No explicit local preference; an MDM or macOS default may apply"
fi

config_updates=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall 2>/dev/null)
if [[ "$config_updates" == "1" ]]; then
  finding PASS "Security data updates" "Automatic installation is explicitly enabled"
elif [[ "$config_updates" == "0" ]]; then
  finding WARN "Security data updates" "Automatic installation is explicitly disabled"
else
  finding INFO "Security data updates" "No explicit local preference; an MDM or macOS default may apply"
fi

auto_login=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1)
auto_login_rc=$?
if (( auto_login_rc == 0 )) && [[ -n "$auto_login" ]]; then
  finding FAIL "Automatic login" "Enabled for a local account"
elif [[ "$auto_login" == *"does not exist"* ]]; then
  finding PASS "Automatic login" "No automatic-login account configured"
else
  finding UNKN "Automatic login" "Unable to read or interpret the configured account"
fi

screen_lock=$(capture sysadminctl -screenLock status)
if [[ "$screen_lock" == *"screenLock is off"* ]]; then
  finding FAIL "Screen lock" "Password requirement is disabled"
elif [[ "$screen_lock" == *"screenLock delay is immediate"* ]]; then
  finding PASS "Screen lock" "Password is required immediately"
elif [[ "$screen_lock" == *"screenLock delay is"* ]]; then
  delay=$(print -r -- "$screen_lock" | sed -E 's/.*screenLock delay is ([0-9]+).*/\1/' | tail -1)
  if [[ "$delay" == <-> ]] && (( delay <= 900 )); then
    finding PASS "Screen lock" "Password required within ${delay} seconds"
  elif [[ "$delay" == <-> ]]; then
    finding WARN "Screen lock" "Password delay is ${delay} seconds; confirm policy"
  else
    finding INFO "Screen lock" "$screen_lock"
  fi
else
  finding UNKN "Screen lock" "Unable to determine password-delay policy"
fi

mdm=$(capture profiles status -type enrollment)
if [[ "$mdm" == *"MDM enrollment: Yes"* ]]; then
  finding PASS "Device management" "MDM enrolled"
elif (( REQUIRE_MDM )); then
  finding FAIL "Device management" "MDM enrollment was required but not detected"
else
  finding INFO "Device management" "MDM enrollment not detected"
fi

console_user=$(stat -f '%Su' /dev/console 2>/dev/null)
if [[ -n "$console_user" && "$console_user" != "root" && "$console_user" != "loginwindow" ]]; then
  admin_check=$(capture dseditgroup -o checkmember -m "$console_user" admin)
  if [[ "$admin_check" == *" yes "* || "$admin_check" == *"is a member of"* ]]; then
    finding WARN "Local administrator" "The signed-in user is an administrator; confirm least-privilege policy"
  elif [[ "$admin_check" == *" no "* || "$admin_check" == *"is not a member of"* ]]; then
    finding PASS "Local administrator" "The signed-in user is a standard user"
  else
    finding UNKN "Local administrator" "Unable to determine group membership"
  fi
else
  finding INFO "Local administrator" "No interactive console user detected"
fi

if lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1; then
  finding WARN "Remote login" "A service is listening on TCP 22"
else
  finding PASS "Remote login" "No TCP 22 listener detected"
fi

if lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then
  finding WARN "Screen sharing" "A service is listening on TCP 5900"
else
  finding PASS "Screen sharing" "No TCP 5900 listener detected"
fi

xprotect_version=$(pkgutil --pkg-info com.apple.pkg.XProtectPlistConfigData 2>/dev/null | awk '/version:/ {print $2; exit}')
[[ -n "$xprotect_version" ]] && finding INFO "XProtect data" "Installed package version ${xprotect_version}"

if (( CHECK_UPDATES )); then
  print "Scanning for updates (this may take several minutes)..."
  available=$(softwareupdate --list 2>&1)
  update_rc=$?
  if (( update_rc != 0 )); then
    finding UNKN "Available updates" "Scan failed: $(print -r -- "$available" | tail -1)"
  elif [[ "$available" == *"No new software available"* ]]; then
    finding PASS "Available updates" "No new updates reported"
  else
    finding WARN "Available updates" "Updates may be available; review Software Update"
  fi
fi

print -r -- "--------------------------------------------------------------------"
print "Summary: ${PASS_COUNT} passed, ${WARN_COUNT} warnings, ${FAIL_COUNT} failures, ${UNKNOWN_COUNT} unknown, ${INFO_COUNT} informational"
print "This is a baseline review, not proof of compliance. MDM policy remains authoritative."

if (( FAIL_COUNT > 0 )); then
  exit 2
elif (( WARN_COUNT > 0 || UNKNOWN_COUNT > 0 )); then
  exit 1
fi
exit 0
