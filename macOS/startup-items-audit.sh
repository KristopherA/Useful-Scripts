#!/bin/bash
#
# startup-items-audit.sh — macOS Startup Items Auditor
#
# Enumerates all LaunchDaemons, LaunchAgents, login items, and kernel
# extensions across system and all user accounts. Flags items with
# missing binaries, unusual paths, or unsigned executables.
#
# Usage:
#   ./startup-items-audit.sh          # current user agents only
#   sudo ./startup-items-audit.sh     # all users + full detail
#
# Output saved to ~/Desktop/startup-audit-*.txt
#
# Requirements: macOS, bash 3.2+, built-in tools only (PlistBuddy, codesign,
# launchctl, osascript). Read-only: nothing is modified or removed.

set -uo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${HOME}/Desktop"; [[ -d "$REPORT_DIR" ]] || REPORT_DIR="$HOME"
REPORT_FILE="${REPORT_DIR}/startup-audit-$(hostname -s)-${TIMESTAMP}.txt"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

IS_ROOT=false; [[ "${EUID}" -eq 0 ]] && IS_ROOT=true
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "$USER")

_log()    { echo -e "$1" | tee -a "$REPORT_FILE"; }
section() { _log ""; _log "${BOLD}── $1${RESET}"; }
ok()      { _log "${GREEN}  ✓${RESET}  $*"; }
flag()    { _log "${RED}  ✗${RESET}  $*"; }
warn()    { _log "${YELLOW}  ⚠${RESET}  $*"; }
info()    { _log "${CYAN}  ℹ${RESET}  $*"; }

TOTAL_ITEMS=0
FLAGGED=0

# ── Inspect a single plist ────────────────────────────────────────────
inspect_plist() {
  local plist="$1"
  local scope="$2"   # "system" or "user:username"
  local label binary enabled issues=()

  TOTAL_ITEMS=$(( TOTAL_ITEMS + 1 ))

  label=$(defaults read "$plist" Label 2>/dev/null || echo "(no label)")

  # Get the program path — try Program first, then ProgramArguments[0].
  # PlistBuddy returns the exact string (paths with spaces stay intact).
  binary=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$plist" 2>/dev/null || \
           /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null || \
           echo "")

  # Check: binary exists
  if [[ -n "$binary" ]] && [[ "$binary" != "(null)" ]]; then
    if [[ ! -e "$binary" ]]; then
      issues+=("missing binary: ${binary}")
    else
      # Check code signature
      CODESIGN=$(codesign -v "$binary" 2>&1 || true)
      if echo "$CODESIGN" | grep -q "not signed"; then
        issues+=("unsigned binary: ${binary}")
      fi
    fi
  fi

  # Check: RunAtLoad
  RUN_AT_LOAD=$(defaults read "$plist" RunAtLoad 2>/dev/null || echo "0")

  # Check: unusual path patterns
  PLIST_PATH="$plist"
  if echo "$PLIST_PATH" | grep -qE "/tmp/|/var/tmp/|\.\."; then
    issues+=("unusual path: ${PLIST_PATH}")
  fi

  # Check: loaded state
  if [[ "$IS_ROOT" == "true" ]]; then
    LOADED=$(launchctl list "$label" 2>/dev/null | grep -v "Could not" || echo "")
    [[ -n "$LOADED" ]] && STATUS="loaded" || STATUS="not loaded"
  else
    STATUS="(need sudo to check load state)"
  fi

  # Output
  local name
  name="$(basename "$plist" .plist)"
  if [[ "${#issues[@]}" -gt 0 ]]; then
    flag "${name}  [${scope}]  ${STATUS}"
    for issue in "${issues[@]}"; do
      _log "        ${RED}→ ${issue}${RESET}"
    done
    FLAGGED=$(( FLAGGED + 1 ))
  else
    _log "  ${DIM}${name}  [${scope}]  ${STATUS}${RESET}"
  fi
}

# ── Scan a directory of plists ────────────────────────────────────────
scan_dir() {
  local dir="$1"
  local scope="$2"
  if [[ ! -d "$dir" ]]; then return; fi

  local count=0
  while IFS= read -r -d '' plist; do
    inspect_plist "$plist" "$scope"
    count=$(( count + 1 ))
  done < <(find "$dir" -maxdepth 1 -name "*.plist" -print0 2>/dev/null)

  [[ "$count" -eq 0 ]] && info "  (none)"
}

# ── Header ────────────────────────────────────────────────────────────
{
  echo "════════════════════════════════════════"
  echo "  Startup Items Audit"
  echo "  Host:  $(hostname)"
  echo "  macOS: $(sw_vers -productVersion)"
  echo "  Date:  $(date)"
  [[ "$IS_ROOT" == "false" ]] && echo "  Note:  run with sudo for all users + load state"
  echo "════════════════════════════════════════"
} | tee "$REPORT_FILE"

# ══════════════════════════════════════════════════════════════════════
# SYSTEM LAUNCH DAEMONS
# ══════════════════════════════════════════════════════════════════════
section "System LaunchDaemons  (/Library/LaunchDaemons)"
scan_dir /Library/LaunchDaemons "system-daemon"

# ══════════════════════════════════════════════════════════════════════
# SYSTEM LAUNCH AGENTS
# ══════════════════════════════════════════════════════════════════════
section "System LaunchAgents  (/Library/LaunchAgents)"
scan_dir /Library/LaunchAgents "system-agent"

# ══════════════════════════════════════════════════════════════════════
# USER LAUNCH AGENTS
# ══════════════════════════════════════════════════════════════════════
section "User LaunchAgents  (~/Library/LaunchAgents)"

if [[ "$IS_ROOT" == "true" ]]; then
  # All users
  for USER_HOME in /Users/*/; do
    UNAME="${USER_HOME%/}"; UNAME="${UNAME##*/}"
    [[ "$UNAME" == "Shared" ]] && continue
    scan_dir "${USER_HOME}Library/LaunchAgents" "user:${UNAME}"
  done
else
  scan_dir "${HOME}/Library/LaunchAgents" "user:${CONSOLE_USER}"
fi

# ══════════════════════════════════════════════════════════════════════
# LOGIN ITEMS (GUI)
# ══════════════════════════════════════════════════════════════════════
section "Login Items  (System Settings > General > Login Items)"

LOGIN_ITEMS=$(osascript -e \
  'tell application "System Events" to get the name of every login item' \
  2>/dev/null | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' || echo "")

if [[ -z "$LOGIN_ITEMS" ]]; then
  info "(none, or could not read)"
else
  while IFS= read -r item; do
    _log "  ${DIM}${item}${RESET}"
    TOTAL_ITEMS=$(( TOTAL_ITEMS + 1 ))
  done <<< "$LOGIN_ITEMS"
fi

# ══════════════════════════════════════════════════════════════════════
# KERNEL EXTENSIONS
# ══════════════════════════════════════════════════════════════════════
section "Kernel Extensions  (/Library/Extensions  +  /System/Library/Extensions)"

KEXT_COUNT=0
while IFS= read -r -d '' kext; do
  KEXT_NAME="${kext##*/}"
  # Skip Apple-signed system kexts to reduce noise
  TEAM=$(codesign -dv "$kext" 2>&1 | grep "TeamIdentifier" | awk '{print $2}' || echo "")
  if [[ "$TEAM" != "0000000000" ]] && ! echo "$kext" | grep -q "/System/Library"; then
    # codesign -v prints nothing on success; rely on its exit status.
    if ! codesign -v "$kext" >/dev/null 2>&1; then
      flag "${KEXT_NAME}  [kext — not signed]"
      FLAGGED=$(( FLAGGED + 1 ))
    else
      _log "  ${DIM}${KEXT_NAME}  [kext]${RESET}"
    fi
    KEXT_COUNT=$(( KEXT_COUNT + 1 ))
    TOTAL_ITEMS=$(( TOTAL_ITEMS + 1 ))
  fi
done < <(find /Library/Extensions -maxdepth 1 -name "*.kext" -print0 2>/dev/null)

[[ "$KEXT_COUNT" -eq 0 ]] && info "No third-party kernel extensions found"

# ══════════════════════════════════════════════════════════════════════
# CRON JOBS
# ══════════════════════════════════════════════════════════════════════
section "Cron Jobs"

CRON_COUNT=0
# System crontab
if [[ -f /etc/crontab ]]; then
  warn "/etc/crontab exists:"
  grep -v '^#\|^$' /etc/crontab | while read -r line; do
    _log "  ${DIM}  ${line}${RESET}"
  done
  CRON_COUNT=$(( CRON_COUNT + 1 ))
fi

# Per-user crontabs
if [[ "$IS_ROOT" == "true" ]]; then
  for UNAME in $(dscl . -list /Users | grep -v '^_'); do
    USER_CRON=$(crontab -u "$UNAME" -l 2>/dev/null | grep -v '^#\|^$' || echo "")
    if [[ -n "$USER_CRON" ]]; then
      warn "Cron jobs for user ${UNAME}:"
      echo "$USER_CRON" | while read -r line; do _log "    ${DIM}${line}${RESET}"; done
      CRON_COUNT=$(( CRON_COUNT + 1 ))
    fi
  done
else
  USER_CRON=$(crontab -l 2>/dev/null | grep -v '^#\|^$' || echo "")
  if [[ -n "$USER_CRON" ]]; then
    info "Cron jobs for current user:"
    echo "$USER_CRON" | while read -r line; do _log "  ${DIM}${line}${RESET}"; done
    CRON_COUNT=$(( CRON_COUNT + 1 ))
  fi
fi

[[ "$CRON_COUNT" -eq 0 ]] && ok "No cron jobs found"

# ══════════════════════════════════════════════════════════════════════
# LOGIN HOOKS (legacy, rare but used by malware)
# ══════════════════════════════════════════════════════════════════════
section "Login/Logout Hooks  (legacy)"

LOGIN_HOOK=$(defaults read com.apple.loginwindow LoginHook 2>/dev/null || echo "")
LOGOUT_HOOK=$(defaults read com.apple.loginwindow LogoutHook 2>/dev/null || echo "")

if [[ -n "$LOGIN_HOOK" ]];  then flag "LoginHook set: ${LOGIN_HOOK}";   FLAGGED=$(( FLAGGED + 1 )); fi
if [[ -n "$LOGOUT_HOOK" ]]; then flag "LogoutHook set: ${LOGOUT_HOOK}"; FLAGGED=$(( FLAGGED + 1 )); fi
[[ -z "$LOGIN_HOOK" ]] && [[ -z "$LOGOUT_HOOK" ]] && ok "No login/logout hooks set"

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════
{
  echo ""
  echo "════════════════════════════════════════"
  echo "  AUDIT SUMMARY"
  echo "  Total items: ${TOTAL_ITEMS}"
  echo "  Flagged:     ${FLAGGED}"
  if [[ "$FLAGGED" -eq 0 ]]; then
    echo "  ✓ No issues found."
  else
    echo "  ✗ ${FLAGGED} item(s) flagged — review above."
  fi
  echo "  Report: ${REPORT_FILE}"
  echo "════════════════════════════════════════"
} | tee -a "$REPORT_FILE"
