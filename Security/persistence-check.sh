#!/bin/bash
#
# persistence-check.sh — macOS Persistence Mechanism Checker
#
# Purpose:
#   Checks locations commonly used by malware and unwanted software to
#   survive reboots: LaunchAgents/Daemons, hidden files, executables in temp
#   dirs, cron/at jobs, login/logout hooks, shell init files, kernel
#   extensions, and XProtect/MRT versions.
#
#   This script does NOT remove anything — it only reports.
#
# Usage:
#   ./persistence-check.sh              # current user scope
#   sudo ./persistence-check.sh         # full system scope (all users)
#
#   REPORT_DIR=/path ./persistence-check.sh   # override report location
#
# Requirements:
#   macOS (uses stat -f, defaults, PlistBuddy, dscl, codesign, sw_vers).
#
# Output:
#   Report saved to $REPORT_DIR (default ~/Desktop, falls back to ~) as
#   persistence-check-<host>-<timestamp>.txt

set -uo pipefail

# ── Configuration (env-overridable) ───────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${REPORT_DIR:-${HOME}/Desktop}"; [[ -d "$REPORT_DIR" ]] || REPORT_DIR="$HOME"
REPORT_FILE="${REPORT_DIR}/persistence-check-$(hostname -s)-${TIMESTAMP}.txt"
MIN_USER_UID="${MIN_USER_UID:-500}"   # macOS regular users start at 501

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

IS_ROOT=false; [[ "${EUID}" -eq 0 ]] && IS_ROOT=true

_log()    { echo -e "$1" | tee -a "$REPORT_FILE"; }
section() { _log ""; _log "${BOLD}── $1${RESET}"; }
clean()   { _log "${GREEN}  ✓${RESET}  $*"; }
flag()    { _log "${RED}  ✗ SUSPICIOUS${RESET}  $*"; FLAGGED=$(( FLAGGED + 1 )); }
warn()    { _log "${YELLOW}  ⚠${RESET}  $*"; WARNED=$(( WARNED + 1 )); }
info()    { _log "${CYAN}  ℹ${RESET}  $*"; }
detail()  { _log "     ${DIM}$*${RESET}"; }

FLAGGED=0; WARNED=0

# List local (non-system) user accounts as "name:uid:home".
# macOS keeps local users in Directory Services, not /etc/passwd.
list_local_users() {
  if command -v dscl >/dev/null 2>&1; then
    dscl . -list /Users UniqueID 2>/dev/null | while read -r uname uid; do
      [[ "$uid" =~ ^[0-9]+$ ]] || continue
      [[ "$uid" -lt "$MIN_USER_UID" ]] && continue
      local home
      home=$(dscl . -read "/Users/${uname}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
      echo "${uname}:${uid}:${home}"
    done
  else
    while IFS=: read -r uname _ uid _ _ home _; do
      [[ "$uid" =~ ^[0-9]+$ ]] || continue
      [[ "$uid" -lt "$MIN_USER_UID" ]] && continue
      echo "${uname}:${uid}:${home}"
    done < /etc/passwd
  fi
}

{
  echo "════════════════════════════════════════"
  echo "  Persistence Mechanism Check"
  echo "  Host:  $(hostname)"
  echo "  macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  echo "  Date:  $(date)"
  [[ "$IS_ROOT" == "false" ]] && echo "  Note:  run with sudo for full system coverage"
  echo "════════════════════════════════════════"
} | tee "$REPORT_FILE"

# ── Helper: check a plist for suspicious indicators ───────────────────
check_plist_suspicious() {
  local plist="$1"
  local name; name="$(basename "$plist")"
  local binary issues=()

  # Program, or first element of ProgramArguments
  binary=$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2>/dev/null || \
           /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2>/dev/null || \
           echo "")

  # Suspicious binary locations
  case "$binary" in
    /tmp/*|/private/tmp/*|/var/tmp/*|/private/var/tmp/*|/dev/shm/*)
      issues+=("binary in temp dir: ${binary}") ;;
    /Users/*/Library/Application\ Support/*/*)
      : ;; # normal app support location
    /Users/*/.*/*)
      issues+=("binary in hidden dot-dir: ${binary}") ;;
  esac

  # Binary is world-writable (other-write bit set)
  if [[ -n "$binary" ]] && [[ -e "$binary" ]]; then
    local perms; perms=$(stat -f "%OLp" "$binary" 2>/dev/null || echo "")
    if [[ "$perms" =~ ^[0-7]+$ ]] && (( 8#$perms & 2 )); then
      issues+=("world-writable binary: ${binary} (${perms})")
    fi
  fi

  if echo "$plist" | grep -qE "\.(tmp|bak|old)\.plist$"; then
    issues+=("suspicious file extension: ${name}")
  fi

  if [[ "${#issues[@]}" -gt 0 ]]; then
    flag "${plist}"
    for i in "${issues[@]}"; do _log "        ${RED}→ ${i}${RESET}"; done
  fi
}

# ══════════════════════════════════════════════════════════════════════
# 1. LAUNCH AGENTS / DAEMONS — suspicious pattern scan
# ══════════════════════════════════════════════════════════════════════
section "1. LaunchAgent / LaunchDaemon Pattern Analysis"
SECTION_START=$FLAGGED

DIRS_TO_CHECK=(
  "/Library/LaunchDaemons"
  "/Library/LaunchAgents"
)
[[ "$IS_ROOT" == "true" ]] && DIRS_TO_CHECK+=("/var/root/Library/LaunchAgents")

if [[ "$IS_ROOT" == "true" ]]; then
  for UDIR in /Users/*/Library/LaunchAgents; do
    [[ -d "$UDIR" ]] && DIRS_TO_CHECK+=("$UDIR")
  done
else
  DIRS_TO_CHECK+=("${HOME}/Library/LaunchAgents")
fi

PLIST_COUNT=0
for DIR in "${DIRS_TO_CHECK[@]}"; do
  [[ -d "$DIR" ]] || continue
  while IFS= read -r -d '' plist; do
    check_plist_suspicious "$plist"
    PLIST_COUNT=$(( PLIST_COUNT + 1 ))
  done < <(find "$DIR" -maxdepth 1 -name "*.plist" -print0 2>/dev/null)
done

[[ "$FLAGGED" -eq "$SECTION_START" ]] && clean "No suspicious patterns in ${PLIST_COUNT} LaunchAgent/Daemon plists"

# ══════════════════════════════════════════════════════════════════════
# 2. HIDDEN FILES IN COMMON LOCATIONS
# ══════════════════════════════════════════════════════════════════════
section "2. Hidden Files in Sensitive Locations"

check_hidden() {
  local dir="$1" label="$2"
  [[ -d "$dir" ]] || return
  local count
  count=$(find "$dir" -maxdepth 1 -name ".*" -not -name ".DS_Store" \
          -not -name ".localized" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    warn "${count} hidden item(s) in ${label}:"
    find "$dir" -maxdepth 1 -name ".*" -not -name ".DS_Store" \
      -not -name ".localized" 2>/dev/null | head -10 | while IFS= read -r f; do
        detail "$(ls -lad "$f" 2>/dev/null | head -1)"
    done
  fi
}

check_hidden "/Library" "/Library"
check_hidden "/usr/local" "/usr/local"

if [[ "$IS_ROOT" == "true" ]]; then
  for UDIR in /Users/*/; do
    [[ "$(basename "$UDIR")" == "Shared" ]] && continue
    check_hidden "${UDIR}Library/Application Support" "$(basename "$UDIR")/Library/Application Support"
  done
else
  check_hidden "${HOME}/Library/Application Support" "~/Library/Application Support"
fi

# ══════════════════════════════════════════════════════════════════════
# 3. EXECUTABLES IN /tmp AND /var/tmp
# ══════════════════════════════════════════════════════════════════════
section "3. Executables in Temp Directories"

TMP_EXEC=$(find /tmp/ /var/tmp/ -maxdepth 3 -type f -perm +111 \
           -not -name "*.dylib" 2>/dev/null | head -20)
if [[ -n "$TMP_EXEC" ]]; then
  flag "Executable files found in /tmp or /var/tmp:"
  echo "$TMP_EXEC" | while IFS= read -r f; do
    detail "$(ls -la "$f" 2>/dev/null)"
  done
else
  clean "No executables in /tmp or /var/tmp"
fi

# ══════════════════════════════════════════════════════════════════════
# 4. CRON JOBS
# ══════════════════════════════════════════════════════════════════════
section "4. Cron Jobs"

CRON_FOUND=false
if [[ -f /etc/crontab ]] && grep -qvE '^#|^$' /etc/crontab; then
  flag "/etc/crontab has entries:"; CRON_FOUND=true
  grep -vE '^#|^$' /etc/crontab | while IFS= read -r line; do detail "$line"; done
fi

if [[ "$IS_ROOT" == "true" ]]; then
  while IFS=: read -r uname _ _; do
    UCRON=$(crontab -u "$uname" -l 2>/dev/null | grep -vE '^#|^$' || echo "")
    if [[ -n "$UCRON" ]]; then
      warn "Cron jobs for ${uname}:"; CRON_FOUND=true
      echo "$UCRON" | while IFS= read -r line; do detail "$line"; done
    fi
  done < <(list_local_users)
  # root's own crontab
  RCRON=$(crontab -l 2>/dev/null | grep -vE '^#|^$' || echo "")
  if [[ -n "$RCRON" ]]; then
    warn "Cron jobs for root:"; CRON_FOUND=true
    echo "$RCRON" | while IFS= read -r line; do detail "$line"; done
  fi
else
  UCRON=$(crontab -l 2>/dev/null | grep -vE '^#|^$' || echo "")
  if [[ -n "$UCRON" ]]; then
    warn "Cron jobs for ${USER}:"; CRON_FOUND=true
    echo "$UCRON" | while IFS= read -r line; do detail "$line"; done
  fi
fi

[[ "$CRON_FOUND" == "false" ]] && clean "No cron jobs found"

# ══════════════════════════════════════════════════════════════════════
# 5. AT JOBS
# ══════════════════════════════════════════════════════════════════════
section "5. Scheduled 'at' Jobs"

AT_JOBS=$(atq 2>/dev/null || echo "")
if [[ -n "$AT_JOBS" ]]; then
  warn "Pending 'at' jobs:"
  echo "$AT_JOBS" | while IFS= read -r line; do detail "$line"; done
else
  clean "No 'at' jobs scheduled"
fi

# ══════════════════════════════════════════════════════════════════════
# 6. LOGIN / LOGOUT HOOKS (legacy persistence)
# ══════════════════════════════════════════════════════════════════════
section "6. Login / Logout Hooks"

LOGIN_HOOK=$(defaults read com.apple.loginwindow LoginHook 2>/dev/null || echo "")
LOGOUT_HOOK=$(defaults read com.apple.loginwindow LogoutHook 2>/dev/null || echo "")

if [[ -n "$LOGIN_HOOK" ]];  then flag "LoginHook:  ${LOGIN_HOOK}"; fi
if [[ -n "$LOGOUT_HOOK" ]]; then flag "LogoutHook: ${LOGOUT_HOOK}"; fi
[[ -z "$LOGIN_HOOK" ]] && [[ -z "$LOGOUT_HOOK" ]] && clean "No login/logout hooks set"

# ══════════════════════════════════════════════════════════════════════
# 7. SHELL INIT FILES
# ══════════════════════════════════════════════════════════════════════
section "7. Shell Init Files (.bash_profile, .zshrc, .zprofile, ...)"
SECTION_START=$FLAGGED

check_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return
  # Look for curl|wget piped to a shell, base64 decoding, eval of downloads
  local SUSPICIOUS
  SUSPICIOUS=$(grep -nE \
    'curl.*\|.*(ba|z)?sh|wget.*\|.*sh|eval.*curl|eval.*wget|base64.*(-d|--decode|-D).*(eval|sh)|python.*exec.*urllib' \
    "$file" 2>/dev/null || echo "")
  if [[ -n "$SUSPICIOUS" ]]; then
    flag "Suspicious content in ${file}:"
    echo "$SUSPICIOUS" | while IFS= read -r line; do detail "$line"; done
  fi
}

INIT_FILES=(.bash_profile .bashrc .zshrc .zprofile .zshenv .zlogin .profile)
if [[ "$IS_ROOT" == "true" ]]; then
  for UDIR in /Users/*/; do
    [[ "$(basename "$UDIR")" == "Shared" ]] && continue
    for f in "${INIT_FILES[@]}"; do
      check_env_file "${UDIR}${f}"
    done
  done
else
  for f in "${INIT_FILES[@]}"; do
    check_env_file "${HOME}/${f}"
  done
fi
[[ "$FLAGGED" -eq "$SECTION_START" ]] && clean "No suspicious shell init files"

# ══════════════════════════════════════════════════════════════════════
# 8. KERNEL EXTENSIONS
# ══════════════════════════════════════════════════════════════════════
section "8. Kernel Extensions (kexts)"

KEXT_ISSUES=0
while IFS= read -r -d '' kext; do
  KEXT_NAME="${kext##*/}"
  if ! codesign --verify "$kext" >/dev/null 2>&1; then
    flag "Unsigned or invalid signature: ${KEXT_NAME}"
    KEXT_ISSUES=$(( KEXT_ISSUES + 1 ))
    continue
  fi
  TEAM=$(codesign -dv "$kext" 2>&1 | awk -F= '/TeamIdentifier/ {print $2}')
  info "kext (signed, team ${TEAM:-unknown}): ${KEXT_NAME}"
done < <(find /Library/Extensions -maxdepth 1 -name "*.kext" -print0 2>/dev/null)

[[ "$KEXT_ISSUES" -eq 0 ]] && clean "No unsigned kernel extensions in /Library/Extensions"

# ══════════════════════════════════════════════════════════════════════
# 9. XPROTECT / MRT STATUS
# ══════════════════════════════════════════════════════════════════════
section "9. XProtect / MRT"

XP_VER=$(defaults read \
  /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.meta.plist \
  Version 2>/dev/null || echo "unknown")
info "XProtect version: ${XP_VER}"

MRT_VER=$(defaults read \
  /Library/Apple/System/Library/CoreServices/MRT.app/Contents/version.plist \
  CFBundleShortVersionString 2>/dev/null || echo "unknown (MRT is not present on newer macOS)")
info "MRT version: ${MRT_VER}"

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════
{
  echo ""
  echo "════════════════════════════════════════"
  echo "  PERSISTENCE CHECK SUMMARY"
  printf "  Suspicious items: %d\n" "$FLAGGED"
  printf "  Warnings:         %d\n" "$WARNED"
  echo ""
  if [[ "$FLAGGED" -eq 0 && "$WARNED" -eq 0 ]]; then
    echo "  ✓ No suspicious persistence found."
  elif [[ "$FLAGGED" -eq 0 ]]; then
    echo "  ⚠ No critical findings, but ${WARNED} item(s) warrant review."
  else
    echo "  ✗ ${FLAGGED} suspicious item(s) — investigate before dismissing."
  fi
  echo "  Report: ${REPORT_FILE}"
  echo "════════════════════════════════════════"
} | tee -a "$REPORT_FILE"
