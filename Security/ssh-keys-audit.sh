#!/bin/bash
#
# ssh-keys-audit.sh — SSH Authorized Keys Auditor (macOS)
#
# Purpose:
#   Walks local user home directories and reports every authorized_keys file,
#   showing key type, size, fingerprint, and comment. Flags weak key types
#   (DSA, RSA < 2048), bad file permissions, legacy authorized_keys2 files,
#   keys in unusual locations, and reviews key sshd_config settings.
#
# Usage:
#   sudo ./ssh-keys-audit.sh           # full audit (all local users)
#   ./ssh-keys-audit.sh                # current user only
#
#   REPORT_DIR=/path ./ssh-keys-audit.sh   # override report location
#
# Requirements:
#   macOS (stat -f, dscl, sw_vers) and OpenSSH ssh-keygen.
#   Note: only the main /etc/ssh/sshd_config is inspected; settings in
#   /etc/ssh/sshd_config.d/*.conf includes are not evaluated.
#
# Output:
#   Report saved to $REPORT_DIR (default ~/Desktop, falls back to ~) as
#   ssh-keys-audit-<host>-<timestamp>.txt

set -uo pipefail

# ── Configuration (env-overridable) ───────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${REPORT_DIR:-${HOME}/Desktop}"; [[ -d "$REPORT_DIR" ]] || REPORT_DIR="$HOME"
REPORT_FILE="${REPORT_DIR}/ssh-keys-audit-$(hostname -s)-${TIMESTAMP}.txt"
MIN_USER_UID="${MIN_USER_UID:-500}"   # macOS regular users start at 501
MIN_RSA_BITS="${MIN_RSA_BITS:-2048}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

IS_ROOT=false; [[ "${EUID}" -eq 0 ]] && IS_ROOT=true

_log()    { echo -e "$1" | tee -a "$REPORT_FILE"; }
section() { _log ""; _log "${BOLD}── $1${RESET}"; }
ok()      { _log "${GREEN}  ✓${RESET}  $*"; }
flag()    { _log "${RED}  ✗${RESET}  $*"; }
warn()    { _log "${YELLOW}  ⚠${RESET}  $*"; }
info()    { _log "${CYAN}  ℹ${RESET}  $*"; }

TOTAL_KEYS=0
FLAGGED_KEYS=0

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

# Read the first value of an sshd_config directive (case-insensitive).
sshd_value() {
  grep -iE "^[[:space:]]*$1[[:space:]]" "$SSHD_CONFIG" 2>/dev/null | head -1 | awk '{print $2}'
}

{
  echo "════════════════════════════════════════"
  echo "  SSH Authorized Keys Audit"
  echo "  Host:  $(hostname)"
  echo "  macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  echo "  Date:  $(date)"
  [[ "$IS_ROOT" == "false" ]] && echo "  Note:  run with sudo to audit all users"
  echo "════════════════════════════════════════"
} | tee "$REPORT_FILE"

# ── Audit a single authorized_keys file ──────────────────────────────
audit_keys_file() {
  local keys_file="$1"
  local owner="$2"

  [[ -f "$keys_file" ]] || return

  # Check permissions — authorized_keys should be 600 (644 tolerated)
  local perms
  perms=$(stat -f "%OLp" "$keys_file" 2>/dev/null || echo "000")
  if [[ "$perms" != "600" ]] && [[ "$perms" != "644" ]]; then
    warn "Permissions ${perms} on ${keys_file} — should be 600"
  fi

  local key_count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    key_count=$(( key_count + 1 ))
    TOTAL_KEYS=$(( TOTAL_KEYS + 1 ))

    # ssh-keygen -l output: "<bits> <fingerprint> <comment...> (<TYPE>)"
    # It understands authorized_keys option prefixes (command="...", etc.).
    local kg bits fp key_type comment
    kg=$(printf '%s\n' "$line" | ssh-keygen -l -f /dev/stdin 2>/dev/null || echo "")
    if [[ -z "$kg" ]]; then
      flag "  [${owner}] unparseable key line in ${keys_file}"
      FLAGGED_KEYS=$(( FLAGGED_KEYS + 1 ))
      continue
    fi
    bits=$(awk '{print $1}' <<<"$kg")
    fp=$(awk '{print $2}' <<<"$kg")
    key_type=$(awk '{print $NF}' <<<"$kg" | tr -d '()')
    comment=$(awk '{ $1=""; $2=""; $NF=""; sub(/^ +/, ""); sub(/ +$/, ""); print }' <<<"$kg")

    # Flag weak key types
    local issues=""
    case "$key_type" in
      DSA)
        issues="DSA keys are insecure and deprecated" ;;
      RSA)
        if [[ "$bits" =~ ^[0-9]+$ ]] && [[ "$bits" -lt "$MIN_RSA_BITS" ]]; then
          issues="RSA key < ${MIN_RSA_BITS} bits (${bits} bits) — too weak"
        fi ;;
    esac

    if [[ -n "$issues" ]]; then
      flag "  [${owner}] ${key_type}-${bits}  fp: ${fp}  comment: ${comment}"
      _log "         ${RED}→ ${issues}${RESET}"
      FLAGGED_KEYS=$(( FLAGGED_KEYS + 1 ))
    else
      _log "  ${DIM}[${owner}] ${key_type}-${bits}  fp: ${fp}  comment: ${comment}${RESET}"
    fi

  done < "$keys_file"

  [[ "$key_count" -eq 0 ]] && info "[${owner}] ${keys_file}: empty file"
}

# ══════════════════════════════════════════════════════════════════════
# USER AUTHORIZED KEYS
# ══════════════════════════════════════════════════════════════════════
section "User authorized_keys Files"

if [[ "$IS_ROOT" == "true" ]]; then
  while IFS=: read -r uname _ home; do
    [[ -z "$home" ]] && continue
    [[ "$home" == /var/empty* ]] && continue
    [[ -d "$home" ]] || continue

    KEYS_FILE="${home}/.ssh/authorized_keys"
    if [[ -f "$KEYS_FILE" ]]; then
      info "Found: ${KEYS_FILE}"
      audit_keys_file "$KEYS_FILE" "$uname"
    fi

    # Also check non-standard authorized_keys2 (legacy)
    KEYS2_FILE="${home}/.ssh/authorized_keys2"
    if [[ -f "$KEYS2_FILE" ]]; then
      warn "Legacy authorized_keys2 found: ${KEYS2_FILE}"
      audit_keys_file "$KEYS2_FILE" "${uname}(keys2)"
    fi
  done < <(list_local_users)
else
  KEYS_FILE="${HOME}/.ssh/authorized_keys"
  if [[ -f "$KEYS_FILE" ]]; then
    info "Found: ${KEYS_FILE}"
    audit_keys_file "$KEYS_FILE" "$USER"
  else
    info "No authorized_keys for current user"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# SYSTEM-WIDE AUTHORIZED KEYS
# ══════════════════════════════════════════════════════════════════════
section "System-wide SSH Key Locations"

if [[ -f "$SSHD_CONFIG" ]]; then
  CUSTOM_KEYS_DIR=$(sshd_value AuthorizedKeysFile)
  if [[ -n "$CUSTOM_KEYS_DIR" ]] && [[ "$CUSTOM_KEYS_DIR" != ".ssh/authorized_keys" ]]; then
    warn "Custom AuthorizedKeysFile directive: ${CUSTOM_KEYS_DIR}"
  else
    ok "AuthorizedKeysFile: standard location (.ssh/authorized_keys)"
  fi
fi

# /etc/ssh/authorized_keys (unusual)
if [[ -d /etc/ssh/authorized_keys ]]; then
  warn "/etc/ssh/authorized_keys/ directory exists — non-standard:"
  while IFS= read -r -d '' f; do
    info "  ${f}"
    audit_keys_file "$f" "system"
  done < <(find /etc/ssh/authorized_keys -type f -print0 2>/dev/null)
fi

# Root's authorized_keys
if [[ -f /var/root/.ssh/authorized_keys ]]; then
  warn "Root has authorized_keys:"
  audit_keys_file /var/root/.ssh/authorized_keys "root"
fi

# ══════════════════════════════════════════════════════════════════════
# SSHD CONFIGURATION REVIEW
# ══════════════════════════════════════════════════════════════════════
section "sshd Configuration"

if [[ -f "$SSHD_CONFIG" ]]; then
  ROOT_LOGIN=$(sshd_value PermitRootLogin);         ROOT_LOGIN="${ROOT_LOGIN:-not set}"
  PASS_AUTH=$(sshd_value PasswordAuthentication);   PASS_AUTH="${PASS_AUTH:-not set}"
  MAX_AUTH=$(sshd_value MaxAuthTries)
  ALLOWED_USERS=$(grep -iE "^[[:space:]]*(AllowUsers|AllowGroups)[[:space:]]" "$SSHD_CONFIG" 2>/dev/null | head -2)

  case "$ROOT_LOGIN" in
    no)        ok   "PermitRootLogin: no" ;;
    "not set") warn "PermitRootLogin: not explicitly set (defaults vary by OS version)" ;;
    *)         flag "PermitRootLogin: ${ROOT_LOGIN} — should be 'no'" ;;
  esac

  case "$PASS_AUTH" in
    no)        ok   "PasswordAuthentication: no (key-only login)" ;;
    "not set") warn "PasswordAuthentication: not set (defaults to yes)" ;;
    *)         warn "PasswordAuthentication: ${PASS_AUTH} — consider 'no' for key-only auth" ;;
  esac

  if [[ "$MAX_AUTH" =~ ^[0-9]+$ ]] && [[ "$MAX_AUTH" -le 4 ]]; then
    ok "MaxAuthTries: ${MAX_AUTH}"
  else
    warn "MaxAuthTries: ${MAX_AUTH:-default (6)} — recommend ≤ 4"
  fi

  if [[ -n "$ALLOWED_USERS" ]]; then
    ok "User/group allowlist configured"
  else
    info "No AllowUsers/AllowGroups set — all accounts can attempt SSH"
  fi
else
  info "No ${SSHD_CONFIG} found (SSH may not be enabled)"
fi

# ══════════════════════════════════════════════════════════════════════
# KNOWN HOSTS (informational)
# ══════════════════════════════════════════════════════════════════════
section "Known Hosts (informational)"

if [[ "$IS_ROOT" == "true" ]]; then
  for UDIR in /Users/*/; do
    KH="${UDIR}.ssh/known_hosts"
    if [[ -f "$KH" ]]; then
      KH_ENTRIES=$(wc -l < "$KH" | tr -d ' ')
      info "$(basename "$UDIR"): ${KH_ENTRIES} known host(s)"
    fi
  done
else
  KH="${HOME}/.ssh/known_hosts"
  [[ -f "$KH" ]] && info "$(wc -l < "$KH" | tr -d ' ') known host entries"
fi

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════
{
  echo ""
  echo "════════════════════════════════════════"
  echo "  AUDIT SUMMARY"
  printf "  Total keys found: %d\n" "$TOTAL_KEYS"
  printf "  Flagged:          %d\n" "$FLAGGED_KEYS"
  if [[ "$TOTAL_KEYS" -eq 0 ]]; then
    echo "  ✓ No authorized_keys entries found."
  elif [[ "$FLAGGED_KEYS" -eq 0 ]]; then
    echo "  ✓ All keys look clean."
  else
    echo "  ✗ ${FLAGGED_KEYS} key(s) flagged — review above."
  fi
  echo "  Report: ${REPORT_FILE}"
  echo "════════════════════════════════════════"
} | tee -a "$REPORT_FILE"
