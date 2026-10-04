#!/bin/bash
#
# upgrade-readiness.sh - macOS Upgrade Readiness Checker
#
# Verifies prerequisites before upgrading to a target macOS version:
# disk space, RAM, battery health, model support, storage, pending
# updates, known incompatible applications and network reachability.
# Read-only: makes no changes to the system.
#
# Usage:
#   ./upgrade-readiness.sh              # default target (TARGET_MAJOR, 15 = Sequoia)
#   ./upgrade-readiness.sh --target 14  # check readiness for Sonoma
#   TARGET_MAJOR=15 ./upgrade-readiness.sh
#
# Requirements: macOS, stock /bin/bash (3.2+). sudo not required.
#
# Note: the per-version requirement and model tables below are a starting
# point; verify against Apple's current compatibility list before relying
# on them for a new macOS release.

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────
TARGET_MAJOR="${TARGET_MAJOR:-15}"          # default: Sequoia
MIN_BATTERY_HEALTH_PASS="${MIN_BATTERY_HEALTH_PASS:-80}"   # % of design capacity
MIN_BATTERY_HEALTH_WARN="${MIN_BATTERY_HEALTH_WARN:-60}"
UPDATE_HOST="${UPDATE_HOST:-swscan.apple.com}"
COMPAT_URL="${COMPAT_URL:-https://support.apple.com/en-us/105113}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_MAJOR="${2:-$TARGET_MAJOR}"; shift 2 ;;
    *)        shift ;;
  esac
done

# ── Lookup tables (functions instead of associative arrays so the
#    script runs under macOS's stock bash 3.2) ────────────────────────

os_name() {
  case "$1" in
    13) echo "Ventura" ;;
    14) echo "Sonoma" ;;
    15) echo "Sequoia" ;;
    *)  echo "macOS $1" ;;
  esac
}

# "min_disk_gb min_ram_gb min_battery_pct"
requirements() {
  case "$1" in
    13) echo "26 8 0" ;;
    14) echo "26 8 0" ;;
    15) echo "20 8 0" ;;
    *)  echo "20 8 0" ;;
  esac
}

# Supported model identifiers: "ModelPrefix<MinGeneration>" tokens
supported_models() {
  case "$1" in
    13) echo "MacBookAir8 MacBookPro15 Macmini8 iMac19 iMacPro1 MacPro7 Mac13" ;;
    14) echo "MacBookAir8 MacBookPro15 Macmini8 iMac19 iMacPro1 MacPro7 Mac13" ;;
    15) echo "MacBookAir9 MacBookPro15 Macmini8 iMac19 MacPro7 Mac13" ;;
    *)  echo "" ;;
  esac
}

# Apps known to have compatibility issues: "App Name:Note|App Name:Note"
known_incompatible() {
  case "$1" in
    15) echo "Adobe Flash Player:Flash is EOL and blocked|32-bit App:32-bit apps do not run on macOS 10.15+" ;;
    14) echo "Adobe Flash Player:Flash is EOL and blocked" ;;
    13) echo "Adobe Flash Player:Flash is EOL and blocked" ;;
    *)  echo "" ;;
  esac
}

TARGET_NAME="$(os_name "$TARGET_MAJOR")"
REQ="$(requirements "$TARGET_MAJOR")"
MIN_DISK=$(echo "$REQ" | awk '{print $1}')
MIN_RAM=$(echo  "$REQ" | awk '{print $2}')
# shellcheck disable=SC2034  # reserved; battery check uses health % thresholds
MIN_BATT=$(echo "$REQ" | awk '{print $3}')

# ── Colour helpers ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

PASS=0; FAIL=0; WARN=0
pass() { echo -e "${GREEN}  ✓ PASS${RESET}  $*"; PASS=$(( PASS + 1 )); }
fail() { echo -e "${RED}  ✗ FAIL${RESET}  $*"; FAIL=$(( FAIL + 1 )); }
warn() { echo -e "${YELLOW}  ⚠ WARN${RESET}  $*"; WARN=$(( WARN + 1 )); }
info() { echo -e "${CYAN}  ℹ INFO${RESET}  $*"; }
section() { echo; echo -e "${BOLD}── $1${RESET}"; }

# ── Header ────────────────────────────────────────────────────────────
CURRENT_VERSION=$(sw_vers -productVersion)
MODEL_ID=$(system_profiler SPHardwareDataType 2>/dev/null \
           | awk '/Model Identifier/ {print $3}')
SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null \
         | awk '/Serial Number/ {print $4}')

echo
echo -e "${BOLD}macOS Upgrade Readiness Check${RESET}"
echo "  Host:    $(hostname)"
echo "  Current: macOS ${CURRENT_VERSION}"
echo "  Target:  macOS ${TARGET_MAJOR} ${TARGET_NAME}"
echo "  Model:   ${MODEL_ID} (S/N: ${SERIAL})"
echo "  Date:    $(date)"

# ── 1. Current macOS version ──────────────────────────────────────────
section "Current OS Version"
CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
if [[ "$CURRENT_MAJOR" -ge "$TARGET_MAJOR" ]]; then
  warn "Already running macOS ${CURRENT_MAJOR} — target is ${TARGET_MAJOR}"
elif [[ $(( TARGET_MAJOR - CURRENT_MAJOR )) -gt 2 ]]; then
  warn "Upgrading ${CURRENT_MAJOR} → ${TARGET_MAJOR} is a large jump — consider incremental upgrades"
else
  pass "Current version ${CURRENT_VERSION} is eligible to upgrade to ${TARGET_MAJOR}"
fi

# ── 2. Available disk space ───────────────────────────────────────────
section "Disk Space  (minimum: ${MIN_DISK} GB free)"
DISK_FREE_KB=$(df -k / | awk 'NR==2 {print $4}')
DISK_FREE_GB=$(( DISK_FREE_KB / 1024 / 1024 ))
DISK_TOTAL_GB=$(( $(df -k / | awk 'NR==2 {print $2}') / 1024 / 1024 ))

if [[ "$DISK_FREE_GB" -ge "$MIN_DISK" ]]; then
  pass "Free space: ${DISK_FREE_GB} GB free of ${DISK_TOTAL_GB} GB total"
elif [[ "$DISK_FREE_GB" -ge $(( MIN_DISK / 2 )) ]]; then
  warn "Free space: ${DISK_FREE_GB} GB — borderline, ${MIN_DISK} GB recommended"
else
  fail "Free space: ${DISK_FREE_GB} GB — need at least ${MIN_DISK} GB free"
  info "Free up space: empty Trash, clear caches, or remove large files"
fi

# ── 3. RAM ────────────────────────────────────────────────────────────
section "Memory  (minimum: ${MIN_RAM} GB)"
RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
RAM_GB=$(( RAM_BYTES / 1024 / 1024 / 1024 ))

if [[ "$RAM_GB" -ge "$MIN_RAM" ]]; then
  pass "RAM: ${RAM_GB} GB"
else
  fail "RAM: ${RAM_GB} GB — minimum is ${MIN_RAM} GB for macOS ${TARGET_MAJOR}"
fi

# ── 4. Battery health (laptops only) ─────────────────────────────────
section "Battery Health"
IOREG_BATT=$(ioreg -rn AppleSmartBattery 2>/dev/null)
# Anchor on top-level keys only (nested dictionaries repeat some names).
DESIGN_CAP=$(echo "$IOREG_BATT" | awk '/^[[:space:]]*"DesignCapacity" =/ {print $NF; exit}')
# On Apple Silicon "MaxCapacity" is a percentage; the mAh value is in
# "AppleRawMaxCapacity". Prefer the raw value when present.
MAX_CAP=$(echo "$IOREG_BATT" | awk '/^[[:space:]]*"AppleRawMaxCapacity" =/ {print $NF; exit}')
[[ -n "$MAX_CAP" ]] || \
  MAX_CAP=$(echo "$IOREG_BATT" | awk '/^[[:space:]]*"MaxCapacity" =/ {print $NF; exit}')

if [[ -z "$DESIGN_CAP" ]] || [[ "$DESIGN_CAP" == "0" ]]; then
  info "No battery detected (desktop Mac)"
else
  HEALTH_PCT=$(awk "BEGIN {printf \"%d\", (${MAX_CAP:-0}/$DESIGN_CAP)*100}" 2>/dev/null || echo "0")
  CYCLES=$(echo "$IOREG_BATT" | awk '/^[[:space:]]*"CycleCount" =/ {print $NF; exit}')
  if [[ "$HEALTH_PCT" -ge "$MIN_BATTERY_HEALTH_PASS" ]]; then
    pass "Battery health: ${HEALTH_PCT}% (${CYCLES} cycles)"
  elif [[ "$HEALTH_PCT" -ge "$MIN_BATTERY_HEALTH_WARN" ]]; then
    warn "Battery health: ${HEALTH_PCT}% — may not sustain a long upgrade; keep plugged in"
  else
    fail "Battery health: ${HEALTH_PCT}% — degraded; plug in before upgrading and consider battery service"
  fi
fi

# ── 5. Model support ──────────────────────────────────────────────────
section "Model Compatibility"

SUPPORTED_LIST="$(supported_models "$TARGET_MAJOR")"
MODEL_SUPPORTED=false

if [[ -z "$SUPPORTED_LIST" ]]; then
  warn "No compatibility list defined for macOS ${TARGET_MAJOR} — check ${COMPAT_URL}"
else
  for PREFIX in $SUPPORTED_LIST; do
    # Extract prefix name and min generation from token (e.g. MacBookPro15 → MacBookPro, min gen 15)
    MODEL_PREFIX=$(echo "$PREFIX" | sed 's/[0-9]*$//')
    MIN_GEN=$(echo "$PREFIX" | grep -oE '[0-9]+$')

    # Require a digit right after the prefix so "Mac" does not match "MacBookPro".
    if echo "$MODEL_ID" | grep -qE "^${MODEL_PREFIX}[0-9]"; then
      # Extract this model's generation number
      THIS_GEN=$(echo "$MODEL_ID" | grep -oE '[0-9]+' | head -1)
      if [[ "${THIS_GEN:-0}" -ge "${MIN_GEN:-0}" ]]; then
        MODEL_SUPPORTED=true
        break
      fi
    fi
  done

  if [[ "$MODEL_SUPPORTED" == "true" ]]; then
    pass "Model ${MODEL_ID} is supported on macOS ${TARGET_MAJOR} ${TARGET_NAME}"
  else
    fail "Model ${MODEL_ID} may NOT be supported on macOS ${TARGET_MAJOR} ${TARGET_NAME}"
    info "Verify at: ${COMPAT_URL}"
  fi
fi

# ── 6. Storage type / APFS ────────────────────────────────────────────
section "Storage"
FS_TYPE=$(diskutil info / 2>/dev/null | awk '/Type \(Bundle\)/ {print $NF}')
if echo "$FS_TYPE" | grep -qi "apfs"; then
  pass "File system: APFS (required for macOS upgrades)"
else
  fail "File system: ${FS_TYPE} — macOS upgrades require APFS"
fi

SMART=$(diskutil info disk0 2>/dev/null | awk '/SMART Status/ {print $NF}' || echo "N/A")
if echo "$SMART" | grep -qi "verified"; then
  pass "SMART status: Verified"
elif [[ -z "$SMART" ]] || echo "$SMART" | grep -qi "N/A\|Not Supported\|Supported"; then
  info "SMART status: Not supported (Apple Silicon / external drive)"
else
  fail "SMART status: ${SMART} — disk may be failing"
fi

# ── 7. Pending software updates ───────────────────────────────────────
section "Pending Updates"
PENDING=$(softwareupdate -l 2>&1 | grep -c "^\*" || true)
if [[ "$PENDING" -eq 0 ]]; then
  pass "No pending software updates"
else
  warn "${PENDING} pending update(s) — install before upgrading"
fi

# ── 8. Known incompatible apps ────────────────────────────────────────
section "Application Compatibility"
INCOMPAT="$(known_incompatible "$TARGET_MAJOR")"
ISSUES_FOUND=0

if [[ -n "$INCOMPAT" ]]; then
  IFS='|' read -ra APP_LIST <<< "$INCOMPAT"
  for ENTRY in "${APP_LIST[@]}"; do
    APP_NAME="${ENTRY%%:*}"
    APP_NOTE="${ENTRY##*:}"
    # Search /Applications for the app name
    FOUND=$(find /Applications -maxdepth 2 -name "*${APP_NAME}*" 2>/dev/null | head -1)
    if [[ -n "$FOUND" ]]; then
      warn "Found: ${APP_NAME} — ${APP_NOTE}"
      ISSUES_FOUND=$(( ISSUES_FOUND + 1 ))
    fi
  done
fi

# Check for any 32-bit apps (won't run on macOS 10.15+, all modern versions)
THIRTYTWO_BIT=$(system_profiler SPApplicationsDataType 2>/dev/null \
  | grep -c "64-Bit.*No" || true)
if [[ "$THIRTYTWO_BIT" -gt 0 ]]; then
  warn "${THIRTYTWO_BIT} 32-bit app(s) detected — will not run on macOS ${TARGET_MAJOR}"
else
  pass "No 32-bit apps detected"
fi

[[ "$ISSUES_FOUND" -eq 0 ]] && pass "No known incompatible apps found"

# ── 9. Network (for download) ─────────────────────────────────────────
section "Network Connectivity"
if ping -c 1 -W 3 "$UPDATE_HOST" &>/dev/null; then
  pass "Apple Software Update servers: reachable"
else
  warn "Cannot reach ${UPDATE_HOST} — confirm network access for upgrade download"
fi

# ── Summary ───────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL + WARN ))
SCORE=0
[[ "$TOTAL" -gt 0 ]] && SCORE=$(( PASS * 100 / TOTAL ))

echo
echo "════════════════════════════════════════"
echo "  READINESS SUMMARY — macOS ${TARGET_MAJOR} ${TARGET_NAME}"
echo "════════════════════════════════════════"
printf "  %-8s %d\n" "PASS:" "$PASS"
printf "  %-8s %d\n" "FAIL:" "$FAIL"
printf "  %-8s %d\n" "WARN:" "$WARN"
echo "  ────────────────────────────────────"
printf "  Score: %d/%d (%d%%)\n" "$PASS" "$TOTAL" "$SCORE"
echo
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  echo -e "  ${GREEN}✓ Ready to upgrade.${RESET}"
elif [[ "$FAIL" -eq 0 ]]; then
  echo -e "  ${YELLOW}⚠ Upgrade possible but review warnings first.${RESET}"
else
  echo -e "  ${RED}✗ Not ready — resolve ${FAIL} failure(s) before upgrading.${RESET}"
fi
echo "════════════════════════════════════════"
echo
