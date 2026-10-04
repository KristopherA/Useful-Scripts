#!/bin/bash
#
# map-network-shares.sh - Mount SMB Network Shares on macOS
#
# Reads share definitions from a config file and mounts them via SMB.
# Prompts for credentials once and reuses them for all shares.
#
# Config file location (first match wins):
#   $SHARES_CONF                       — explicit override (env var)
#   ~/.network-shares.conf             — user-specific overrides
#   /etc/network-shares.conf           — system-wide share list
#   <script directory>/network-shares.conf
#
# Config file format (one share per line, # for comments):
#   Display Name|smb://server/share|/Volumes/MountPoint
#
# Example:
#   Staff Files|smb://fileserver.example.com/Staff|/Volumes/Staff
#   IT Share|smb://fileserver.example.com/IT|/Volumes/IT
#   Software|smb://fileserver.example.com/Software|/Volumes/Software
#
# Usage:
#   ./map-network-shares.sh              # mount all shares
#   ./map-network-shares.sh --unmount    # unmount all shares
#   ./map-network-shares.sh --status     # show mount status only
#   ./map-network-shares.sh --list       # list configured shares
#
# Requirements: macOS, stock /bin/bash (3.2+), mount_smbfs.
# Note: creating mount points under /Volumes may require admin rights on
# recent macOS; use a path under $HOME (e.g. ~/Shares/Staff) if needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_NAME="network-shares.conf"
NETWORK_HINT="${NETWORK_HINT:-the corporate network or VPN}"
MODE="mount"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unmount) MODE="unmount" ;;
    --status)  MODE="status"  ;;
    --list)    MODE="list"    ;;
    *) ;;
  esac
  shift
done

# ── Colour helpers ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

ok()   { echo -e "${GREEN}  ✓${RESET}  $*"; }
fail() { echo -e "${RED}  ✗${RESET}  $*"; }
warn() { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
info() { echo -e "${CYAN}  ℹ${RESET}  $*"; }

# Trim leading/trailing whitespace
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Percent-encode a string for use in a URL userinfo component
urlencode() {
  local s="$1" out="" c i
  local LC_ALL=C
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# ── Find config file ──────────────────────────────────────────────────
CONF_FILE=""
for CANDIDATE in \
  "${SHARES_CONF:-}" \
  "${HOME}/.${CONF_NAME}" \
  "/etc/${CONF_NAME}" \
  "${SCRIPT_DIR}/${CONF_NAME}"; do
  if [[ -n "$CANDIDATE" && -f "$CANDIDATE" ]]; then
    CONF_FILE="$CANDIDATE"
    break
  fi
done

if [[ -z "$CONF_FILE" ]]; then
  warn "No config file found. Creating a template at ${SCRIPT_DIR}/${CONF_NAME}"
  cat > "${SCRIPT_DIR}/${CONF_NAME}" <<'EOF'
# Network Shares Configuration
# Format: Display Name|SMB URL|Local Mount Point
# Lines starting with # are ignored.
#
# Examples:
# Staff Files|smb://fileserver.example.com/Staff|/Volumes/Staff
# IT Share|smb://fileserver.example.com/IT|/Volumes/IT
# Software Repo|smb://fileserver.example.com/Software|/Volumes/Software
# Home Drive|smb://fileserver.example.com/Homes|/Volumes/HomeDir
EOF
  info "Edit ${SCRIPT_DIR}/${CONF_NAME} then re-run this script."
  exit 0
fi

info "Config: ${CONF_FILE}"

# ── Parse config ──────────────────────────────────────────────────────
SHARE_NAMES=()
SHARE_URLS=()
SHARE_MOUNTS=()

while IFS='|' read -r name url mount; do
  name="$(trim "$name")"
  # Skip comments and blank lines
  [[ -z "$name" ]] && continue
  [[ "$name" =~ ^# ]] && continue
  SHARE_NAMES+=("$name")
  SHARE_URLS+=("$(trim "$url")")
  SHARE_MOUNTS+=("$(trim "$mount")")
done < <(grep -v '^[[:space:]]*#\|^[[:space:]]*$' "$CONF_FILE")

if [[ "${#SHARE_NAMES[@]}" -eq 0 ]]; then
  warn "No shares defined in ${CONF_FILE}"
  exit 0
fi

# ── --list ────────────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
  echo
  echo -e "${BOLD}Configured shares (${#SHARE_NAMES[@]}):${RESET}"
  for i in "${!SHARE_NAMES[@]}"; do
    printf "  %-20s  %-40s  %s\n" \
      "${SHARE_NAMES[$i]}" "${SHARE_URLS[$i]}" "${SHARE_MOUNTS[$i]}"
  done
  exit 0
fi

# ── --status ──────────────────────────────────────────────────────────
if [[ "$MODE" == "status" ]]; then
  echo
  echo -e "${BOLD}Share Status:${RESET}"
  for i in "${!SHARE_NAMES[@]}"; do
    MOUNT="${SHARE_MOUNTS[$i]}"
    if mount | grep -qF " on ${MOUNT} "; then
      ok "${SHARE_NAMES[$i]} → ${MOUNT}  (mounted)"
    else
      fail "${SHARE_NAMES[$i]} → ${MOUNT}  (not mounted)"
    fi
  done
  exit 0
fi

# ── --unmount ─────────────────────────────────────────────────────────
if [[ "$MODE" == "unmount" ]]; then
  echo
  echo -e "${BOLD}Unmounting shares...${RESET}"
  for i in "${!SHARE_NAMES[@]}"; do
    MOUNT="${SHARE_MOUNTS[$i]}"
    if mount | grep -qF " on ${MOUNT} "; then
      if diskutil unmount "${MOUNT}" &>/dev/null || umount "${MOUNT}" &>/dev/null; then
        ok "Unmounted: ${SHARE_NAMES[$i]}"
      else
        fail "Could not unmount ${SHARE_NAMES[$i]} (${MOUNT}) — check for open files"
      fi
    else
      info "${SHARE_NAMES[$i]}: not mounted"
    fi
  done
  exit 0
fi

# ── Mount ─────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}Mounting ${#SHARE_NAMES[@]} share(s)...${RESET}"

# Check network connectivity to infer the server host
FIRST_URL="${SHARE_URLS[0]}"
SERVER=$(echo "$FIRST_URL" | sed 's|smb://||' | cut -d/ -f1)

if ! ping -c 1 -W 2 "$SERVER" &>/dev/null; then
  warn "Cannot ping ${SERVER} — are you on ${NETWORK_HINT}?"
  read -rp "Continue anyway? (y/N): " CONT
  [[ "$CONT" =~ ^[Yy]$ ]] || exit 0
fi

# Prompt for credentials once
echo
read -rp "  Username (domain\\user or user): " SMB_USER
read -rsp "  Password: " SMB_PASS
echo

# Domain\user is expressed as DOMAIN;user in SMB URLs
if [[ "$SMB_USER" == *\\* ]]; then
  ENC_USER="$(urlencode "${SMB_USER%%\\*}");$(urlencode "${SMB_USER#*\\}")"
else
  ENC_USER="$(urlencode "$SMB_USER")"
fi
ENC_PASS="$(urlencode "$SMB_PASS")"

MOUNTED=0; FAILED=0

for i in "${!SHARE_NAMES[@]}"; do
  NAME="${SHARE_NAMES[$i]}"
  URL="${SHARE_URLS[$i]}"
  MOUNT="${SHARE_MOUNTS[$i]}"

  # Already mounted?
  if mount | grep -qF " on ${MOUNT} "; then
    ok "${NAME}: already mounted at ${MOUNT}"
    MOUNTED=$(( MOUNTED + 1 ))
    continue
  fi

  # Create mount point if needed
  mkdir -p "$MOUNT" 2>/dev/null || { fail "${NAME}: cannot create ${MOUNT}"; FAILED=$(( FAILED + 1 )); continue; }

  # Build authenticated URL: //user:pass@server/share (credentials percent-encoded)
  URL_AUTH="//${ENC_USER}:${ENC_PASS}@${URL#smb://}"

  if mount_smbfs "$URL_AUTH" "$MOUNT" 2>/dev/null; then
    ok "${NAME}: mounted at ${MOUNT}"
    MOUNTED=$(( MOUNTED + 1 ))
  else
    # Fall back to open (opens in Finder, less scriptable but always works)
    if open "${URL}" 2>/dev/null; then
      warn "${NAME}: opened via Finder (mount_smbfs failed — check credentials)"
    else
      fail "${NAME}: failed to mount ${URL}"
    fi
    FAILED=$(( FAILED + 1 ))
  fi
done

unset SMB_PASS ENC_PASS URL_AUTH

echo
echo "  Mounted: ${MOUNTED}  |  Failed: ${FAILED}"
[[ "$FAILED" -gt 0 ]] && info "Check credentials and VPN. Run with --status to verify."
exit 0
