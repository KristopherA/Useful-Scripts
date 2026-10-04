#!/bin/bash
#
# macos-compliance-check.sh — macOS Security Compliance Checker
#
# Checks workstation settings against CIS macOS Benchmark v3.0 and
# Apple Platform Security guidance. Uses only macOS-native tools.
#
# Run as the logged-in user for accurate per-user settings (screen lock,
# screen saver). Run with sudo for deeper checks (FileVault user list,
# remote login, NTP, MDM enrollment).
#
# Usage:
#   ./macos-compliance-check.sh              # current user
#   sudo ./macos-compliance-check.sh         # full detail
#
# Read-only: reports settings, makes no changes. A text report is saved
# to REPORT_DIR (default: ~/Desktop, falling back to ~).
#
# Thresholds below default to CIS-style values; override them via
# environment variables to match your own policy, e.g.
#   MAX_SCREENSAVER_SECS=600 ./macos-compliance-check.sh
#
# Supported: macOS 13 Ventura, 14 Sonoma, 15 Sequoia
#
# Benchmarks:
#   CIS Apple macOS Benchmark v3.0
#   Apple Platform Security Guide (2024)
#   NIST SP 800-179 macOS Security Config Guide

set -uo pipefail

SCRIPT_VERSION="1.1"
HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ── Policy thresholds (env-overridable) ───────────────────────────────
MAX_SCREENSAVER_SECS="${MAX_SCREENSAVER_SECS:-1200}"     # CIS 2.3.1 max idle before screen saver
PREFERRED_SCREENSAVER_SECS="${PREFERRED_SCREENSAVER_SECS:-600}"
MAX_PASSWORD_DELAY_SECS="${MAX_PASSWORD_DELAY_SECS:-5}"  # CIS 2.3.2 max delay before password required
MAX_DISPLAY_SLEEP_MIN="${MAX_DISPLAY_SLEEP_MIN:-20}"
PREFERRED_DISPLAY_SLEEP_MIN="${PREFERRED_DISPLAY_SLEEP_MIN:-10}"
RECOMMENDED_MIN_PW_LEN="${RECOMMENDED_MIN_PW_LEN:-15}"
# Regex of NTP servers considered authoritative
TRUSTED_NTP_REGEX="${TRUSTED_NTP_REGEX:-apple\.com|time\.cloudflare|pool\.ntp|time\.google}"

# Save report to Desktop if it exists, otherwise home directory
REPORT_DIR="${REPORT_DIR:-${HOME}/Desktop}"
[[ -d "$REPORT_DIR" ]] || REPORT_DIR="$HOME"
REPORT_FILE="${REPORT_DIR}/compliance-${HOSTNAME_SHORT}-${TIMESTAMP}.txt"

# ── Colour codes (disabled when not a terminal) ───────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ── Result counters ───────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0; INFO_COUNT=0

# ── Output helpers ────────────────────────────────────────────────────
_log() { echo -e "$1" | tee -a "$REPORT_FILE"; }

pass() { _log "${GREEN}  ✓ PASS${RESET}  $1"; PASS=$(( PASS + 1 )); }
fail() { _log "${RED}  ✗ FAIL${RESET}  $1"; FAIL=$(( FAIL + 1 )); }
warn() { _log "${YELLOW}  ⚠ WARN${RESET}  $1"; WARN=$(( WARN + 1 )); }
info() { _log "${CYAN}  ℹ INFO${RESET}  $1"; INFO_COUNT=$(( INFO_COUNT + 1 )); }

section() {
  _log ""
  _log "${BOLD}── $1${RESET}"
}

# Safe defaults read — returns empty string on missing key/domain
d_read()      { defaults read      "$@" 2>/dev/null || true; }
d_read_host() { defaults -currentHost read "$@" 2>/dev/null || true; }

# Integer guard — returns 0 if input is not a plain integer
to_int() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo "0"; }

# ── Pre-flight ────────────────────────────────────────────────────────
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
BUILD=$(sw_vers -buildVersion)
IS_ROOT=false; [[ "${EUID}" -eq 0 ]] && IS_ROOT=true

# When run with sudo, screen saver/lock settings must be read as the
# console user, not root. Identify who is actually sitting at the machine.
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "$USER")

# ── macOS version gate ────────────────────────────────────────────────
if [[ "$OS_MAJOR" -lt 13 ]]; then
  echo "Warning: This script targets macOS 13+. Results on ${OS_VERSION} may be inaccurate." >&2
fi

# ── Report header ─────────────────────────────────────────────────────
{
  echo "════════════════════════════════════════════"
  echo "  macOS Compliance Check v${SCRIPT_VERSION}"
  echo "  Host:    $(hostname)"
  echo "  User:    ${CONSOLE_USER}"
  echo "  macOS:   ${OS_VERSION} (${BUILD})"
  echo "  Date:    $(date)"
  echo "  Root:    ${IS_ROOT}"
  echo "════════════════════════════════════════════"
} | tee "$REPORT_FILE"

if [[ "$IS_ROOT" == "false" ]]; then
  _log "${DIM}  Note: run with sudo for NTP, SSH status, and MDM enrollment checks.${RESET}"
fi

# ══════════════════════════════════════════════════════════════════════
# 1. SOFTWARE UPDATES
#    CIS 1.1–1.5: Automatic update settings
# ══════════════════════════════════════════════════════════════════════
section "1. Software Updates"

AUTO_CHECK=$(d_read /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled)
AUTO_DL=$(d_read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload)
CRITICAL=$(d_read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall)
CONFIG_DATA=$(d_read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall)
APP_UPDATES=$(d_read /Library/Preferences/com.apple.commerce AutoUpdate)

[[ "$AUTO_CHECK" == "1" ]]   && pass "Auto-check for updates: enabled (CIS 1.1)" \
                              || fail "Auto-check for updates: disabled — System Settings > General > Software Update"

[[ "$AUTO_DL" == "1" ]]      && pass "Auto-download updates: enabled (CIS 1.2)" \
                              || warn "Auto-download updates: disabled"

[[ "$CRITICAL" == "1" ]]     && pass "Critical security updates: auto-install (CIS 1.3)" \
                              || fail "Critical security updates: auto-install disabled"

[[ "$CONFIG_DATA" == "1" ]]  && pass "XProtect / MRT data: auto-install (CIS 1.4)" \
                              || warn "XProtect / MRT data: auto-install disabled"

[[ "$APP_UPDATES" == "1" ]]  && pass "App Store app updates: auto-install" \
                              || info "App Store app updates: manual — consider enabling"

# ══════════════════════════════════════════════════════════════════════
# 2. DISK ENCRYPTION (FileVault)
#    CIS 2.6.1: FileVault must be enabled on all volumes
# ══════════════════════════════════════════════════════════════════════
section "2. Disk Encryption (FileVault)"

FV_STATUS=$(fdesetup status 2>/dev/null || echo "Unknown")

if echo "$FV_STATUS" | grep -q "FileVault is On"; then
  pass "FileVault: On (CIS 2.6.1)"
  if [[ "$IS_ROOT" == "true" ]]; then
    FV_USERS=$(fdesetup list 2>/dev/null | wc -l | tr -d ' ')
    info "Enabled users: ${FV_USERS}"
    # Warn if recovery key is institution-held vs personal
    FV_KEY_TYPE=$(fdesetup status 2>/dev/null | grep -i "key" || echo "")
    [[ -n "$FV_KEY_TYPE" ]] && info "Key info: ${FV_KEY_TYPE}"
  fi
elif echo "$FV_STATUS" | grep -q "FileVault is Off"; then
  fail "FileVault: Off — enable in System Settings > Privacy & Security > FileVault"
else
  warn "FileVault: status indeterminate (${FV_STATUS})"
fi

# ══════════════════════════════════════════════════════════════════════
# 3. APPLICATION FIREWALL
#    CIS 2.1.1: Firewall enabled
#    CIS 2.1.2: Stealth mode enabled
# ══════════════════════════════════════════════════════════════════════
section "3. Application Firewall"

FW_BIN="/usr/libexec/ApplicationFirewall/socketfilterfw"

if [[ -x "$FW_BIN" ]]; then
  FW_STATE=$("$FW_BIN" --getglobalstate 2>/dev/null || echo "unknown")
  FW_STEALTH=$("$FW_BIN" --getstealthmode 2>/dev/null || echo "unknown")
  FW_BLOCK=$("$FW_BIN" --getblockall 2>/dev/null || echo "unknown")
  FW_ALLOW_SIGNED=$("$FW_BIN" --getallowsigned 2>/dev/null || echo "unknown")

  if echo "$FW_STATE" | grep -qi "enabled"; then
    pass "Application Firewall: enabled (CIS 2.1.1)"
  else
    fail "Application Firewall: disabled — System Settings > Network > Firewall"
  fi

  if echo "$FW_STEALTH" | grep -qi "enabled"; then
    pass "Stealth mode: enabled — ignores unsolicited ICMP/UDP probes (CIS 2.1.2)"
  else
    warn "Stealth mode: disabled — enable in Firewall Options"
  fi

  if echo "$FW_BLOCK" | grep -qi "enabled"; then
    info "Block all incoming connections: enabled (very restrictive)"
  else
    info "Block all incoming connections: disabled (normal for workstations)"
  fi

  if echo "$FW_ALLOW_SIGNED" | grep -qi "enabled"; then
    info "Allow signed apps: enabled (built-in apps can receive connections)"
  fi
else
  warn "Firewall binary not found — cannot assess firewall state"
fi

# ══════════════════════════════════════════════════════════════════════
# 4. SYSTEM INTEGRITY PROTECTION (SIP)
#    CIS 2.5.5: SIP must be enabled
# ══════════════════════════════════════════════════════════════════════
section "4. System Integrity Protection (SIP)"

SIP_STATUS=$(csrutil status 2>/dev/null || echo "unknown")

if echo "$SIP_STATUS" | grep -q "enabled"; then
  pass "SIP: enabled (CIS 2.5.5)"
elif echo "$SIP_STATUS" | grep -q "disabled"; then
  fail "SIP: disabled — re-enable from macOS Recovery: csrutil enable"
else
  warn "SIP: ${SIP_STATUS}"
fi

# ══════════════════════════════════════════════════════════════════════
# 5. GATEKEEPER
#    CIS 2.5.1: Gatekeeper must be enabled
# ══════════════════════════════════════════════════════════════════════
section "5. Gatekeeper"

GK_STATUS=$(spctl --status 2>/dev/null || echo "unknown")

if echo "$GK_STATUS" | grep -qi "assessments enabled"; then
  pass "Gatekeeper: enabled — App Store + identified developers (CIS 2.5.1)"
elif echo "$GK_STATUS" | grep -qi "disabled"; then
  fail "Gatekeeper: disabled — run: sudo spctl --master-enable"
else
  warn "Gatekeeper: ${GK_STATUS}"
fi

# XProtect version (informational)
XP_VERSION=$(defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.meta.plist Version 2>/dev/null || echo "unknown")
info "XProtect version: ${XP_VERSION}"

# ══════════════════════════════════════════════════════════════════════
# 6. SCREEN LOCK & SCREEN SAVER
#    CIS 2.3.1: Screen saver timeout ≤ 1200 s (20 min)
#    CIS 2.3.2: Password required immediately (delay ≤ 5 s)
#    CIS 2.3.3: Display sleep ≤ 1200 s
#
#    NOTE: These are per-user preferences. If run with sudo the check
#    reads the console user's preferences via `su`.
# ══════════════════════════════════════════════════════════════════════
section "6. Screen Lock & Screen Saver"

# Read as the console user regardless of whether we're root
if [[ "$IS_ROOT" == "true" ]]; then
  SS_TIMEOUT=$(su -l "$CONSOLE_USER" -c "defaults -currentHost read com.apple.screensaver idleTime" 2>/dev/null || echo "")
  ASK_PASS=$(su -l "$CONSOLE_USER" -c "defaults -currentHost read com.apple.screensaver askForPassword" 2>/dev/null || echo "")
  ASK_DELAY=$(su -l "$CONSOLE_USER" -c "defaults -currentHost read com.apple.screensaver askForPasswordDelay" 2>/dev/null || echo "0")
else
  SS_TIMEOUT=$(d_read_host com.apple.screensaver idleTime)
  ASK_PASS=$(d_read_host com.apple.screensaver askForPassword)
  ASK_DELAY=$(d_read_host com.apple.screensaver askForPasswordDelay)
fi

SS_TIMEOUT_INT=$(to_int "$SS_TIMEOUT")
ASK_DELAY_INT=$(to_int "${ASK_DELAY%.*}")   # strip decimal if present

# Screen saver timeout — CIS threshold is 1200 s (20 min)
if [[ "$SS_TIMEOUT_INT" -eq 0 ]] || [[ -z "$SS_TIMEOUT" ]]; then
  fail "Screen saver timeout: not set or disabled (policy requires ≤ ${MAX_SCREENSAVER_SECS} s, CIS 2.3.1)"
elif [[ "$SS_TIMEOUT_INT" -le "$PREFERRED_SCREENSAVER_SECS" ]]; then
  pass "Screen saver timeout: ${SS_TIMEOUT_INT}s / $(( SS_TIMEOUT_INT / 60 )) min — meets $(( PREFERRED_SCREENSAVER_SECS / 60 ))-min preferred setting"
elif [[ "$SS_TIMEOUT_INT" -le "$MAX_SCREENSAVER_SECS" ]]; then
  pass "Screen saver timeout: ${SS_TIMEOUT_INT}s / $(( SS_TIMEOUT_INT / 60 )) min — within $(( MAX_SCREENSAVER_SECS / 60 ))-min maximum"
else
  fail "Screen saver timeout: ${SS_TIMEOUT_INT}s / $(( SS_TIMEOUT_INT / 60 )) min — exceeds $(( MAX_SCREENSAVER_SECS / 60 ))-min maximum (CIS 2.3.1)"
fi

# Password required on wake
if [[ "$ASK_PASS" == "1" ]]; then
  if [[ "$ASK_DELAY_INT" -le "$MAX_PASSWORD_DELAY_SECS" ]]; then
    pass "Password on wake: required — delay ${ASK_DELAY_INT}s (CIS 2.3.2)"
  else
    warn "Password on wake: required but delay is ${ASK_DELAY_INT}s — set to 0 for immediate lock"
  fi
else
  fail "Password on wake: not required — System Settings > Lock Screen > Require password"
fi

# Display sleep via pmset
DISPLAY_SLEEP=$(pmset -g 2>/dev/null | awk '/^[[:space:]]+displaysleep/ {print $2}')
DISPLAY_SLEEP_INT=$(to_int "$DISPLAY_SLEEP")

if [[ "$DISPLAY_SLEEP_INT" -eq 0 ]]; then
  warn "Display sleep: never — set a timeout in System Settings > Displays > Advanced"
elif [[ "$DISPLAY_SLEEP_INT" -le "$PREFERRED_DISPLAY_SLEEP_MIN" ]]; then
  pass "Display sleep: ${DISPLAY_SLEEP_INT} min"
elif [[ "$DISPLAY_SLEEP_INT" -le "$MAX_DISPLAY_SLEEP_MIN" ]]; then
  pass "Display sleep: ${DISPLAY_SLEEP_INT} min — within ${MAX_DISPLAY_SLEEP_MIN}-min threshold"
else
  warn "Display sleep: ${DISPLAY_SLEEP_INT} min — recommend ≤ ${MAX_DISPLAY_SLEEP_MIN} min"
fi

# ══════════════════════════════════════════════════════════════════════
# 7. LOGIN WINDOW SECURITY
#    CIS 2.6.2: Disable automatic login
#    CIS 2.6.4: Disable guest account
# ══════════════════════════════════════════════════════════════════════
section "7. Login Window Security"

AUTO_LOGIN=$(d_read /Library/Preferences/com.apple.loginwindow autoLoginUser)
GUEST=$(d_read /Library/Preferences/com.apple.loginwindow GuestEnabled)
SHOW_FULLNAME=$(d_read /Library/Preferences/com.apple.loginwindow SHOWFULLNAME)
LOGIN_MSG=$(d_read /Library/Preferences/com.apple.loginwindow LoginwindowText)

if [[ -z "$AUTO_LOGIN" ]]; then
  pass "Automatic login: disabled (CIS 2.6.2)"
else
  fail "Automatic login: enabled as '${AUTO_LOGIN}' — disable in System Settings > Users & Groups"
fi

if [[ "$GUEST" == "1" ]]; then
  fail "Guest account: enabled (CIS 2.6.4) — disable in System Settings > Users & Groups"
else
  pass "Guest account: disabled (CIS 2.6.4)"
fi

# Show username + password field instead of user list (CIS 2.6.7)
if [[ "$SHOW_FULLNAME" == "1" ]]; then
  pass "Login window: shows name + password fields (not user list) (CIS 2.6.7)"
else
  warn "Login window: displays user list — consider 'Show name and password' for shared/lab machines"
fi

if [[ -n "$LOGIN_MSG" ]]; then
  pass "Login window message: set ('${LOGIN_MSG:0:60}...')"
else
  info "Login window message: not set — consider adding IT contact / asset tag info"
fi

# ══════════════════════════════════════════════════════════════════════
# 8. REMOTE ACCESS
#    CIS 2.3.3: Disable remote login (SSH) on workstations
#    CIS 2.3.4: Disable remote management unless required
# ══════════════════════════════════════════════════════════════════════
section "8. Remote Access"

if [[ "$IS_ROOT" == "true" ]]; then
  SSH_STATUS=$(systemsetup -getremotelogin 2>/dev/null || echo "unknown")
  if echo "$SSH_STATUS" | grep -qi "Off"; then
    pass "Remote Login (SSH): off (CIS 2.3.3)"
  elif echo "$SSH_STATUS" | grep -qi "On"; then
    warn "Remote Login (SSH): on — intentional for managed/server machines; restrict to known IPs in /etc/ssh/sshd_config"
  else
    info "Remote Login (SSH): ${SSH_STATUS}"
  fi
else
  info "Remote Login (SSH): run with sudo to check (systemsetup requires root)"
fi

# Screen Sharing
SS_LOADED=$(launchctl list com.apple.screensharing 2>/dev/null | grep -v "Could not" || echo "")
ARD_LOADED=$(launchctl list com.apple.RemoteDesktop.agent 2>/dev/null | grep -v "Could not" || echo "")

if [[ -n "$SS_LOADED" ]]; then
  warn "Screen Sharing: active — verify it is intentionally enabled for IT support"
else
  pass "Screen Sharing: not active"
fi

if [[ -n "$ARD_LOADED" ]]; then
  info "Apple Remote Desktop agent: active"
else
  pass "Apple Remote Desktop: not active"
fi

# Remote Apple Events (CIS 2.3.6)
RAE_STATUS=$(systemsetup -getremoteappleevents 2>/dev/null || echo "unknown")
if echo "$RAE_STATUS" | grep -qi "Off"; then
  pass "Remote Apple Events: off (CIS 2.3.6)"
elif echo "$RAE_STATUS" | grep -qi "On"; then
  fail "Remote Apple Events: on — disable unless explicitly required"
else
  info "Remote Apple Events: ${RAE_STATUS} (run with sudo for accurate result)"
fi

# ══════════════════════════════════════════════════════════════════════
# 9. TIME & NTP
#    CIS 2.2.1: Enable network time synchronisation
#    CIS 2.2.2: Use an authoritative NTP source
# ══════════════════════════════════════════════════════════════════════
section "9. Time Synchronisation (NTP)"

if [[ "$IS_ROOT" == "true" ]]; then
  NTP_ENABLED=$(systemsetup -getusingnetworktime 2>/dev/null || echo "unknown")
  NTP_SERVER=$(systemsetup -getnetworktimeserver 2>/dev/null || echo "unknown")

  if echo "$NTP_ENABLED" | grep -qi "On"; then
    pass "Network time: enabled (CIS 2.2.1)"
    info "NTP server: ${NTP_SERVER}"
    # Warn if using a non-Apple/public server — time.apple.com is fine
    if echo "$NTP_SERVER" | grep -qiE "$TRUSTED_NTP_REGEX"; then
      pass "NTP server: known authoritative source"
    else
      warn "NTP server '${NTP_SERVER}' — verify it is an authoritative source (CIS 2.2.2)"
    fi
  else
    fail "Network time: disabled — run: sudo systemsetup -setusingnetworktime on"
  fi
else
  info "NTP status: run with sudo to check (systemsetup requires root)"
fi

# ══════════════════════════════════════════════════════════════════════
# 10. BLUETOOTH
#     CIS 2.1.3: Disable Bluetooth when not in use
# ══════════════════════════════════════════════════════════════════════
section "10. Bluetooth"

BT_POWER=$(d_read /Library/Preferences/com.apple.Bluetooth ControllerPowerState)
BT_SHARING=$(launchctl list com.apple.bluetoothUIServer 2>/dev/null | grep -v "Could not" || echo "")
BT_FILE_SHARING=$(d_read /Library/Preferences/com.apple.Bluetooth PrefKeyServicesEnabled)

if [[ "$BT_POWER" == "0" ]]; then
  pass "Bluetooth: off (CIS 2.1.3)"
elif [[ "$BT_POWER" == "1" ]]; then
  info "Bluetooth: on — disable in System Settings > Bluetooth if not in use (CIS 2.1.3)"
else
  info "Bluetooth: power state unknown"
fi

if [[ "$BT_FILE_SHARING" == "1" ]]; then
  warn "Bluetooth file sharing: enabled — disable unless required"
else
  pass "Bluetooth file sharing: disabled"
fi

# ══════════════════════════════════════════════════════════════════════
# 11. SHARING SERVICES
#     CIS 2.3.x: Disable sharing services not in use
# ══════════════════════════════════════════════════════════════════════
section "11. Sharing Services"

check_sharing() {
  local label="$1" launchd_id="$2"
  local result
  result=$(launchctl list "$launchd_id" 2>/dev/null | grep -v "Could not" || echo "")
  if [[ -n "$result" ]]; then
    warn "${label}: active — disable in System Settings > General > Sharing if not required"
  else
    pass "${label}: not active"
  fi
}

check_sharing "File Sharing (SMB/AFP)"   com.apple.smbd
check_sharing "Printer Sharing"          com.apple.cupsd
check_sharing "Internet Sharing"         com.apple.InternetSharing
check_sharing "Content Caching"          com.apple.AssetCache.builtin

# AirDrop — check per-user setting
AIRDROP=$(d_read_host com.apple.NetworkBrowser DisableAirDrop)
if [[ "$AIRDROP" == "1" ]]; then
  pass "AirDrop: disabled"
else
  info "AirDrop: enabled — acceptable; verify 'Contacts Only' or 'No One' is set"
fi

# ══════════════════════════════════════════════════════════════════════
# 12. PASSWORD POLICY
#     CIS 5.2.x: Local password policy
# ══════════════════════════════════════════════════════════════════════
section "12. Password Policy"

# Read local account policy via pwpolicy
if [[ "$IS_ROOT" == "true" ]]; then
  PWPOLICY=$(pwpolicy -getaccountpolicies 2>/dev/null || echo "")

  if [[ -n "$PWPOLICY" ]] && ! echo "$PWPOLICY" | grep -q "No global policy"; then
    pass "Password policy: account policies configured"
    # Try to extract min length
    MIN_LEN=$(echo "$PWPOLICY" | grep -oE "policyAttributePassword.{0,80}" \
              | grep -oE "minChars[^0-9]*[0-9]+" | grep -oE "[0-9]+$" | head -1 || echo "")
    [[ -n "$MIN_LEN" ]] && info "Min password length from policy: ${MIN_LEN}"
  else
    warn "No global password policy set via pwpolicy — consider enforcing minimum length of ${RECOMMENDED_MIN_PW_LEN} chars (CIS 5.2)"
  fi
else
  info "Password policy: run with sudo to check (pwpolicy requires root)"
fi

# ══════════════════════════════════════════════════════════════════════
# 13. MDM & DIRECTORY
#     CIS 6.x: Ensure machine is managed
# ══════════════════════════════════════════════════════════════════════
section "13. Management (MDM / Directory)"

MDM_STATUS=$(profiles status -type enrollment 2>/dev/null || echo "")
if echo "$MDM_STATUS" | grep -qi "Enrolled via DEP: Yes"; then
  pass "MDM: enrolled via DEP"
elif echo "$MDM_STATUS" | grep -qi "MDM enrollment: Yes"; then
  pass "MDM: enrolled"
elif echo "$MDM_STATUS" | grep -qi "not enrolled"; then
  warn "MDM: not enrolled — unmanaged machine"
else
  info "MDM status: ${MDM_STATUS:-unable to determine} (may need sudo)"
fi

# Directory binding
AD_NODE=$(dscl localhost -list / 2>/dev/null | grep -i "CorporateServer\|active.directory\|ActiveDirectory" || echo "")
if [[ -n "$AD_NODE" ]]; then
  info "Directory: Active Directory node present (${AD_NODE})"
else
  info "Directory: local accounts only (no AD binding detected)"
fi

# ══════════════════════════════════════════════════════════════════════
# 14. PRIVACY & DIAGNOSTICS
# ══════════════════════════════════════════════════════════════════════
section "14. Privacy & Diagnostics"

# Location services
LOC_ENABLED=$(d_read /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled 2>/dev/null || echo "")
if [[ "$LOC_ENABLED" == "0" ]]; then
  info "Location services: disabled"
else
  info "Location services: enabled — review per-app permissions in System Settings > Privacy"
fi

# Diagnostic submission to Apple
DIAG_SUBMIT=$(d_read /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist AutoSubmit 2>/dev/null || echo "")
if [[ "$DIAG_SUBMIT" == "1" ]]; then
  info "Diagnostic data: submitted to Apple — review in System Settings > Privacy > Analytics"
else
  info "Diagnostic data: submission off or not set"
fi

# Siri — informational
SIRI_ENABLED=$(d_read com.apple.assistant.support "Assistant Enabled" 2>/dev/null || echo "")
if [[ "$SIRI_ENABLED" == "1" ]] || [[ "$SIRI_ENABLED" == "YES" ]]; then
  info "Siri: enabled — review data sharing settings if handling sensitive information"
else
  info "Siri: disabled"
fi

# ══════════════════════════════════════════════════════════════════════
# COMPLIANCE SUMMARY
# ══════════════════════════════════════════════════════════════════════
TOTAL=$(( PASS + FAIL + WARN ))
SCORE=0
[[ "$TOTAL" -gt 0 ]] && SCORE=$(( PASS * 100 / TOTAL ))

{
  echo ""
  echo "════════════════════════════════════════════"
  echo "  COMPLIANCE SUMMARY"
  echo "════════════════════════════════════════════"
  printf "  %-8s %d\n" "PASS:"  "$PASS"
  printf "  %-8s %d\n" "FAIL:"  "$FAIL"
  printf "  %-8s %d\n" "WARN:"  "$WARN"
  printf "  %-8s %d\n" "INFO:"  "$INFO_COUNT"
  echo "  ────────────────────────────────────────"
  printf "  Score:   %d/%d checks passed (%d%%)\n" "$PASS" "$TOTAL" "$SCORE"
  echo ""

  if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo "  ✓ Fully compliant — no issues found."
  elif [[ $FAIL -eq 0 ]]; then
    echo "  ⚠ No critical failures, but ${WARN} warning(s) should be reviewed."
  else
    echo "  ✗ ${FAIL} critical failure(s) require remediation."
    [[ $WARN -gt 0 ]] && echo "    ${WARN} additional warning(s) to review."
  fi
  echo ""
  echo "  Report saved to:"
  echo "  ${REPORT_FILE}"
  echo "════════════════════════════════════════════"
} | tee -a "$REPORT_FILE"
