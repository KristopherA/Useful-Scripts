#!/usr/bin/env bash
# battery-health.sh -- macOS battery health, life, and usage summary
#
# Usage:
#   ./battery-health.sh            # battery report
#   ./battery-health.sh --power    # also sample live power draw (prompts for sudo)
#
# Requirements: macOS laptop (ioreg, pmset). --power needs sudo (powermetrics).
# Works on Intel and Apple Silicon. On Apple Silicon, ioreg's MaxCapacity and
# CurrentCapacity are percentages, so the raw mAh values (AppleRawMaxCapacity /
# AppleRawCurrentCapacity, or NominalChargeCapacity) are preferred when present.

set -euo pipefail

# --- gather raw values ---
BATT=$(ioreg -rn AppleSmartBattery 2>/dev/null || true)

if [ -z "$BATT" ]; then
  echo "No internal battery found (desktop Mac or ioreg unavailable)." >&2
  exit 1
fi

# Match only top-level keys ("Key" = value) so nested dictionaries such as
# BatteryData, which repeat some key names inline, do not produce bogus values.
get_val() {
  echo "$BATT" | awk -v k="\"$1\"" '$1 == k && $2 == "=" { gsub(/"/, "", $3); print $3; exit }'
}

# First non-empty value from a list of keys.
first_val() {
  local key val
  for key in "$@"; do
    val=$(get_val "$key")
    if [ -n "$val" ]; then echo "$val"; return; fi
  done
}

DESIGN=$(get_val DesignCapacity)
MAX=$(first_val AppleRawMaxCapacity NominalChargeCapacity MaxCapacity)
CURRENT=$(first_val AppleRawCurrentCapacity CurrentCapacity)
CYCLES=$(get_val CycleCount)
CHARGING=$(get_val IsCharging)
FULL=$(get_val FullyCharged)

if [ -z "$DESIGN" ] || [ -z "$MAX" ] || [ "$DESIGN" -eq 0 ] || [ "$MAX" -eq 0 ]; then
  echo "Unable to read battery capacity values from ioreg." >&2
  exit 1
fi
CURRENT="${CURRENT:-0}"

# --- calculations ---
HEALTH=$(awk "BEGIN {printf \"%.1f\", ($MAX/$DESIGN)*100}")
CHARGE=$(awk "BEGIN {printf \"%.1f\", ($CURRENT/$MAX)*100}")

# --- power source and time remaining ---
PMSET=$(pmset -g batt 2>/dev/null || true)
SOURCE=$(echo "$PMSET" | grep -oE "'[^']+'" | head -1 | tr -d "'" || true)
REMAINING=$(echo "$PMSET" | grep -oE "[0-9]+:[0-9]+ remaining" | head -1 || true)
[ -z "$REMAINING" ] && REMAINING="N/A"

# --- charging state label ---
if   [ "$FULL"     = "Yes" ]; then STATE="Full"
elif [ "$CHARGING" = "Yes" ]; then STATE="Charging"
else                               STATE="Discharging"
fi

# --- health label ---
if   awk "BEGIN {exit !($HEALTH >= 80)}"; then HLABEL="Good"
elif awk "BEGIN {exit !($HEALTH >= 60)}"; then HLABEL="Fair"
else                                           HLABEL="Poor"
fi

# --- output ---
echo "==============================="
echo "  macOS Battery Report"
echo "==============================="
echo "Power Source   : $SOURCE"
echo "State          : $STATE"
echo "Charge         : ${CHARGE}%  ($CURRENT / $MAX mAh)"
echo "Time Remaining : $REMAINING"
echo "-------------------------------"
echo "Battery Health : ${HEALTH}%  ($HLABEL)"
echo "Max Capacity   : $MAX mAh"
echo "Design Capacity: $DESIGN mAh"
echo "Cycle Count    : $CYCLES"
echo "==============================="

# --- optional: live power draw (requires sudo) ---
if [ "${1:-}" = "--power" ]; then
  echo ""
  echo "Live Power Draw (1 sample):"
  sudo powermetrics --samplers battery,cpu_power,gpu_power -n 1 -i 1000 2>/dev/null \
    | grep -E "Discharge rate|CPU Power|GPU Power|State of charge" || true
fi
