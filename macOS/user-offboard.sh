#!/bin/bash
#
# user-offboard.sh - macOS Local User Offboarding
#
# Archives a user's home folder, removes admin rights, disables the
# account (random password + DisabledUser flag, hidden from login window),
# removes matching certificates from the System keychain, and optionally
# deletes the home directory after a successful archive.
#
# Usage:
#   sudo ./user-offboard.sh <username>
#   sudo ./user-offboard.sh               # prompts for username
#   sudo ./user-offboard.sh --dry-run <username>   # show what would happen
#
# Configuration (environment variables):
#   ARCHIVE_DEST  Directory for the home-folder archive (created if missing)
#   LOG_FILE      Log file path
#
# Requirements: macOS, root privileges, local (dscl) user account.
# The script asks for confirmation before making any changes.

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────
ARCHIVE_DEST="${ARCHIVE_DEST:-/Users/Shared/offboarding}"
LOG_FILE="${LOG_FILE:-/var/log/user-offboarding.log}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DRY_RUN=false

# ── Arguments ─────────────────────────────────────────────────────────
TARGET_USER=""
for ARG in "$@"; do
  case "$ARG" in
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *)            TARGET_USER="$ARG" ;;
  esac
done

# ── Colour helpers ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

log()  {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null
  fi
}
ok()   { echo -e "${GREEN}  ✓${RESET} $*"; log "OK: $*" >/dev/null; }
warn() { echo -e "${YELLOW}  ⚠${RESET} $*"; log "WARN: $*" >/dev/null; }
err()  { echo -e "${RED}  ✗${RESET} $*"; log "ERROR: $*" >/dev/null; }
die()  { err "$*"; exit 1; }
yes()  { [[ "$1" =~ ^[Yy]$ ]]; }

# Run a command, or just print it in dry-run mode.
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] $*"
  else
    "$@"
  fi
}

# ── Root check ────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0 [--dry-run] [username]"

# ── Resolve target user ───────────────────────────────────────────────
if [[ -z "$TARGET_USER" ]]; then
  read -rp "Username to offboard: " TARGET_USER
fi

[[ -n "$TARGET_USER" ]] || die "No username provided."

# Confirm user exists
dscl . -read "/Users/${TARGET_USER}" UniqueID &>/dev/null \
  || die "User '${TARGET_USER}' not found in local directory."

HOME_DIR=$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory \
           | awk '{print $2}')
DISPLAY_NAME=$(dscl . -read "/Users/${TARGET_USER}" RealName \
               | sed 's/RealName: //' | xargs)
USER_UID=$(dscl . -read "/Users/${TARGET_USER}" UniqueID \
           | awk '{print $2}')

echo
[[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}${BOLD}DRY RUN — no changes will be made${RESET}"
echo -e "${BOLD}Offboarding: ${TARGET_USER} (${DISPLAY_NAME}, UID ${USER_UID})${RESET}"
echo -e "  Home:    ${HOME_DIR}"
echo -e "  Archive: ${ARCHIVE_DEST}"
echo

# Abort if user is currently logged in
LOGGED_IN=$(who | awk '{print $1}' | grep -c "^${TARGET_USER}$" || true)
if [[ "$LOGGED_IN" -gt 0 ]]; then
  warn "User is currently logged in. Force-log them out first or proceed with caution."
  read -rp "Continue anyway? (y/N): " CONTINUE
  yes "$CONTINUE" || { echo "Aborted."; exit 0; }
fi

read -rp "Proceed with offboarding? (y/N): " CONFIRM
yes "$CONFIRM" || { echo "Aborted."; exit 0; }

log "=== BEGIN offboarding: ${TARGET_USER} (${DISPLAY_NAME}) ===" >/dev/null

# ── 1. Archive home folder ────────────────────────────────────────────
echo
echo -e "${BOLD}Step 1: Archive home folder${RESET}"

run mkdir -p "$ARCHIVE_DEST" || die "Cannot create archive destination: ${ARCHIVE_DEST}"

ARCHIVE_NAME="${TARGET_USER}-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${ARCHIVE_DEST}/${ARCHIVE_NAME}"

if [[ -d "$HOME_DIR" ]]; then
  HOME_BASE="$(basename "$HOME_DIR")"
  echo "  Archiving ${HOME_DIR} → ${ARCHIVE_PATH}"
  echo "  (This may take a while for large home folders...)"

  # Exclude patterns are relative to -C, matching archive member names.
  if run tar -czf "$ARCHIVE_PATH" \
       --exclude="${HOME_BASE}/.Trash" \
       --exclude="${HOME_BASE}/Library/Caches" \
       -C "$(dirname "$HOME_DIR")" \
       "$HOME_BASE" 2>/dev/null; then
    if [[ "$DRY_RUN" == "true" ]]; then
      ok "Archive would be created: ${ARCHIVE_PATH}"
    else
      ok "Archive created: ${ARCHIVE_PATH} ($(du -sh "$ARCHIVE_PATH" | cut -f1))"
    fi
  else
    warn "Archive completed with some errors (check permissions on excluded paths)"
  fi
else
  warn "Home directory '${HOME_DIR}' not found — skipping archive."
fi

# ── 2. Remove admin rights ────────────────────────────────────────────
echo
echo -e "${BOLD}Step 2: Remove admin rights${RESET}"

IS_ADMIN=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null \
           | grep -wc "$TARGET_USER" || true)

if [[ "$IS_ADMIN" -gt 0 ]]; then
  run dscl . -delete /Groups/admin GroupMembership "$TARGET_USER" 2>/dev/null || true
  USER_GUID=$(dscl . -read "/Users/${TARGET_USER}" GeneratedUID 2>/dev/null \
              | awk '{print $2}')
  if [[ -n "$USER_GUID" ]]; then
    run dscl . -delete /Groups/admin GroupMembers "$USER_GUID" 2>/dev/null || true
  fi
  ok "Admin rights removed"
else
  ok "User was not an admin — no change needed"
fi

# ── 3. Disable the account ────────────────────────────────────────────
echo
echo -e "${BOLD}Step 3: Disable account${RESET}"

# Reset the password to a long random value nobody knows.
# (The original set the literal password "*", which is a known value.)
RANDOM_PW="$(openssl rand -base64 33 2>/dev/null || head -c 33 /dev/urandom | base64)"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "    [dry-run] dscl . -passwd /Users/${TARGET_USER} <random>"
else
  dscl . -passwd "/Users/${TARGET_USER}" "$RANDOM_PW" 2>/dev/null \
    || warn "Could not reset password (Secure Token / FileVault users may need sysadminctl)"
fi
unset RANDOM_PW

# Mark account as disabled in AuthenticationAuthority
CURRENT_AA=$(dscl . -read "/Users/${TARGET_USER}" AuthenticationAuthority \
             2>/dev/null | sed 's/AuthenticationAuthority: //' || echo "")
if ! echo "$CURRENT_AA" | grep -q "DisabledUser"; then
  run dscl . -append "/Users/${TARGET_USER}" AuthenticationAuthority ";DisabledUser;" \
    2>/dev/null || warn "Could not set DisabledUser flag (may already be set)"
fi

# Hide from login window
run dscl . -create "/Users/${TARGET_USER}" IsHidden 1 2>/dev/null || true

ok "Account disabled and hidden from login window"

# ── 4. Remove local certificates ──────────────────────────────────────
echo
echo -e "${BOLD}Step 4: Remove local certificates${RESET}"

CERT_COUNT=0
# Remove certificates whose email address starts with "<username>@" from the system keychain
if security find-certificate -a -e "${TARGET_USER}@" /Library/Keychains/System.keychain \
   &>/dev/null; then
  if run security delete-certificate -e "${TARGET_USER}@" \
       /Library/Keychains/System.keychain 2>/dev/null; then
    CERT_COUNT=$(( CERT_COUNT + 1 ))
  fi
fi

if [[ "$CERT_COUNT" -gt 0 ]]; then
  ok "Removed ${CERT_COUNT} certificate(s) from system keychain"
else
  ok "No user certificates found in system keychain"
fi
warn "Manually verify any MDM-issued certificates are revoked in your MDM console"

# ── 5. Optional: remove home directory ───────────────────────────────
echo
echo -e "${BOLD}Step 5: Remove home directory (optional)${RESET}"

if [[ -d "$HOME_DIR" ]]; then
  read -rp "  Delete home directory ${HOME_DIR}? (y/N): " DELETE_HOME
  if yes "$DELETE_HOME"; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] rm -rf '${HOME_DIR}' (only if archive exists and is non-empty)"
    # Double-check archive exists before deleting
    elif [[ -f "$ARCHIVE_PATH" ]] && [[ -s "$ARCHIVE_PATH" ]]; then
      rm -rf "$HOME_DIR"
      ok "Home directory removed"
    else
      warn "Archive not found or empty — refusing to delete home directory"
      warn "Delete manually: rm -rf '${HOME_DIR}'"
    fi
  else
    ok "Home directory retained at ${HOME_DIR}"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════"
echo "  Offboarding complete: ${TARGET_USER}"
[[ "$DRY_RUN" == "true" ]] && echo "  (dry run — nothing was changed)"
echo "════════════════════════════════════════"
echo "  Archive:  ${ARCHIVE_PATH}"
echo "  Log:      ${LOG_FILE}"
echo
echo "  Remaining manual steps:"
echo "  - Revoke MDM certificates / DEP assignment"
echo "  - Remove from directory service groups"
echo "  - Revoke VPN credentials"
echo "  - Transfer or forward email"
echo "  - Recover any assigned hardware"
echo

log "=== END offboarding: ${TARGET_USER} ===" >/dev/null
