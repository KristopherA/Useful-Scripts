#!/bin/bash
#
# wifi-diagnostics.sh — macOS Wi-Fi Diagnostics
#
# Captures current Wi-Fi connection details, signal quality,
# recent disconnect events, DNS, and connectivity to key hosts.
# Uses only macOS-native tools (airport, networksetup, system_profiler).
#
# Usage:
#   ./wifi-diagnostics.sh                      # quick report
#   ./wifi-diagnostics.sh --save               # also save to ~/Desktop
#   ./wifi-diagnostics.sh --host example.com   # add a custom ping target
#
# Requirements: macOS, bash 3.2+. The legacy `airport` utility was removed in
# macOS 14.4; on those systems signal/channel data falls back to
# system_profiler SPAirPortDataType and the nearby-network scan is skipped.
# Newer macOS may hide the SSID/BSSID unless the terminal has Location access.

set -uo pipefail

# Optional extra ping target (can also be set with --host).
CUSTOM_HOST="${WIFI_DIAG_HOST:-}"
SAVE_REPORT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --save)  SAVE_REPORT=true ;;
    --host)
      [[ $# -ge 2 ]] || { echo "Missing value for --host" >&2; exit 64; }
      CUSTOM_HOST="$2"; shift ;;
    *) ;;
  esac
  shift
done

AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

good()    { echo -e "${GREEN}  ✓${RESET}  $*"; }
concern() { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
bad()     { echo -e "${RED}  ✗${RESET}  $*"; }
info()    { echo -e "${CYAN}  ℹ${RESET}  $*"; }
section() { echo; echo -e "${BOLD}── $1${RESET}"; }
raw()     { echo -e "     ${DIM}$*${RESET}"; }

OUTPUT=""
tee_out() {
  [[ "$SAVE_REPORT" == "true" ]] && OUTPUT+="$1"$'\n'
  echo -e "$1"
}

# ── Detect Wi-Fi interface ────────────────────────────────────────────
WIFI_IFACE=$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Wi-Fi/{getline; print $2}' | head -1)
WIFI_IFACE="${WIFI_IFACE:-en0}"

echo -e "${BOLD}Wi-Fi Diagnostics${RESET}"
echo "  Interface: ${WIFI_IFACE}"
echo "  Host:      $(hostname)"
echo "  Date:      $(date)"

# ══════════════════════════════════════════════════════════════════════
# 1. CURRENT CONNECTION
# ══════════════════════════════════════════════════════════════════════
section "Current Connection"

SP_INFO=""
if [[ ! -x "$AIRPORT" ]]; then
  info "airport utility not present (removed in macOS 14.4+); using system_profiler"
  AIRPORT_INFO=""
  # Current Network Information block of the active interface
  SP_INFO=$(system_profiler SPAirPortDataType 2>/dev/null \
    | awk '/Current Network Information:/ {f=1; getline; next} f && /Other Local Wi-Fi Networks:/ {exit} f {print}' || echo "")
else
  AIRPORT_INFO=$("$AIRPORT" -I 2>/dev/null || echo "")
fi

if [[ -n "$SP_INFO" ]]; then
  # Fallback path (no airport binary)
  CHANNEL=$(echo  "$SP_INFO" | awk -F': ' '/Channel:/ {split($2,a," "); print a[1]; exit}')
  PHY_MODE=$(echo "$SP_INFO" | awk -F': ' '/PHY Mode:/ {print $2; exit}')
  SECURITY=$(echo "$SP_INFO" | awk -F': ' '/Security:/ {print $2; exit}')
  TX_RATE=$(echo  "$SP_INFO" | awk -F': ' '/Transmit Rate:/ {print $2; exit}')
  MCS=$(echo      "$SP_INFO" | awk -F': ' '/MCS Index:/ {print $2; exit}')
  RSSI=$(echo     "$SP_INFO" | awk -F': ' '/Signal \/ Noise:/ {split($2,a," "); print a[1]; exit}')
  NOISE=$(echo    "$SP_INFO" | awk -F': ' '/Signal \/ Noise:/ {split($2,a," "); print a[4]; exit}')

  info "PHY mode:  ${PHY_MODE:-unknown}  (channel: ${CHANNEL:-?})"
  info "Security:  ${SECURITY:-unknown}"
  info "TX rate:   ${TX_RATE:-?} Mbps  (MCS: ${MCS:-?})"
fi

if [[ -z "$AIRPORT_INFO" && -z "$SP_INFO" ]] || echo "$AIRPORT_INFO" | grep -q "AirPort: Off"; then
  bad "Wi-Fi is off or not connected"
elif [[ -n "$SP_INFO" && -z "${RSSI:-}" ]]; then
  info "Signal/noise unavailable from system_profiler"
elif [[ -n "$SP_INFO" ]]; then
  RSSI_INT="${RSSI:-0}"
  NOISE_INT="${NOISE:--90}"
  SNR=$(( RSSI_INT - NOISE_INT ))
  if   [[ "$RSSI_INT" -ge -50 ]]; then good    "Signal (RSSI): ${RSSI} dBm — Excellent"
  elif [[ "$RSSI_INT" -ge -60 ]]; then good    "Signal (RSSI): ${RSSI} dBm — Good"
  elif [[ "$RSSI_INT" -ge -70 ]]; then concern "Signal (RSSI): ${RSSI} dBm — Fair (may cause dropouts)"
  elif [[ "$RSSI_INT" -ge -80 ]]; then bad     "Signal (RSSI): ${RSSI} dBm — Weak (intermittent connectivity likely)"
  else                                 bad     "Signal (RSSI): ${RSSI} dBm — Very weak"
  fi
  info "Noise floor: ${NOISE} dBm  |  SNR: ${SNR} dB (want ≥ 25)"
  if   [[ "$SNR" -ge 40 ]]; then good    "SNR: ${SNR} dB — Excellent"
  elif [[ "$SNR" -ge 25 ]]; then good    "SNR: ${SNR} dB — Good"
  elif [[ "$SNR" -ge 15 ]]; then concern "SNR: ${SNR} dB — Marginal"
  else                           bad     "SNR: ${SNR} dB — Poor (interference likely)"
  fi
else
  SSID=$(echo        "$AIRPORT_INFO" | awk '/ SSID:/ {print $2}')
  BSSID=$(echo       "$AIRPORT_INFO" | awk '/BSSID:/ {print $2}')
  CHANNEL=$(echo     "$AIRPORT_INFO" | awk '/channel:/ {print $2}')
  PHY_MODE=$(echo    "$AIRPORT_INFO" | awk '/lastTxRate:/ {print $2}')
  RSSI=$(echo        "$AIRPORT_INFO" | awk '/agrCtlRSSI:/ {print $2}')
  NOISE=$(echo       "$AIRPORT_INFO" | awk '/agrCtlNoise:/ {print $2}')
  TX_RATE=$(echo     "$AIRPORT_INFO" | awk '/lastTxRate:/ {print $2}')
  MCS=$(echo         "$AIRPORT_INFO" | awk '/MCS:/ {print $2}')
  SECURITY=$(echo    "$AIRPORT_INFO" | awk '/link auth:/ {print $3}')

  info "SSID:      ${SSID:-unknown}"
  info "BSSID:     ${BSSID:-unknown}  (channel: ${CHANNEL:-?})"
  info "Security:  ${SECURITY:-unknown}"
  info "TX rate:   ${TX_RATE:-?} Mbps  (MCS: ${MCS:-?})"

  # Signal quality assessment
  RSSI_INT="${RSSI:-0}"
  NOISE_INT="${NOISE:--90}"
  SNR=$(( RSSI_INT - NOISE_INT ))

  if   [[ "$RSSI_INT" -ge -50 ]]; then
    good "Signal (RSSI): ${RSSI} dBm — Excellent"
  elif [[ "$RSSI_INT" -ge -60 ]]; then
    good "Signal (RSSI): ${RSSI} dBm — Good"
  elif [[ "$RSSI_INT" -ge -70 ]]; then
    concern "Signal (RSSI): ${RSSI} dBm — Fair (may cause dropouts)"
  elif [[ "$RSSI_INT" -ge -80 ]]; then
    bad "Signal (RSSI): ${RSSI} dBm — Weak (intermittent connectivity likely)"
  else
    bad "Signal (RSSI): ${RSSI} dBm — Very weak"
  fi

  info "Noise floor: ${NOISE} dBm  |  SNR: ${SNR} dB (want ≥ 25)"
  if   [[ "$SNR" -ge 40 ]]; then good    "SNR: ${SNR} dB — Excellent"
  elif [[ "$SNR" -ge 25 ]]; then good    "SNR: ${SNR} dB — Good"
  elif [[ "$SNR" -ge 15 ]]; then concern "SNR: ${SNR} dB — Marginal"
  else                           bad     "SNR: ${SNR} dB — Poor (interference likely)"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 2. IP CONFIGURATION
# ══════════════════════════════════════════════════════════════════════
section "IP Configuration"

IP_ADDR=$(ipconfig getifaddr "$WIFI_IFACE" 2>/dev/null || echo "none")
SUBNET=$(ipconfig getoption "$WIFI_IFACE" subnet_mask 2>/dev/null || echo "unknown")
ROUTER=$(netstat -rn 2>/dev/null | awk '/^default/ && /'"$WIFI_IFACE"'/ {print $2; exit}' || echo "unknown")
ROUTER="${ROUTER:-unknown}"
DHCP_SERVER=$(ipconfig getoption "$WIFI_IFACE" server_identifier 2>/dev/null || echo "unknown")

if [[ "$IP_ADDR" == "none" ]] || [[ -z "$IP_ADDR" ]]; then
  bad "No IP address on ${WIFI_IFACE} — DHCP may have failed"
else
  good "IP address: ${IP_ADDR}  (subnet: ${SUBNET})"
  info "Gateway:    ${ROUTER}"
  info "DHCP:       ${DHCP_SERVER}"

  # Link-local check (169.x = DHCP failure)
  if echo "$IP_ADDR" | grep -q "^169\.254"; then
    bad "Link-local IP (169.254.x.x) — DHCP assignment failed"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 3. DNS
# ══════════════════════════════════════════════════════════════════════
section "DNS"

DNS_SERVERS=$(networksetup -getdnsservers Wi-Fi 2>/dev/null \
              | grep -v "There aren't any")
if [[ -z "$DNS_SERVERS" ]]; then
  # Fall back to scutil
  DNS_SERVERS=$(scutil --dns 2>/dev/null | awk '/nameserver/ {print $3}' | sort -u | head -4)
fi

if [[ -z "$DNS_SERVERS" ]]; then
  bad "No DNS servers configured"
else
  info "DNS servers: $(echo "$DNS_SERVERS" | tr '\n' '  ')"

  # Test resolution
  if dscacheutil -q host -a name apple.com 2>/dev/null | grep -q "ip_address"; then
    good "DNS resolution: OK (apple.com resolves)"
  elif host apple.com &>/dev/null 2>&1; then
    good "DNS resolution: OK"
  else
    bad "DNS resolution: FAILED for apple.com"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 4. CONNECTIVITY TESTS
# ══════════════════════════════════════════════════════════════════════
section "Connectivity"

ping_test() {
  local host="$1" label="$2"
  local RTT
  # macOS ping -W is in milliseconds
  RTT=$(ping -c 3 -W 2000 "$host" 2>/dev/null \
        | awk '/round-trip/ {print $4}' | cut -d/ -f2 || echo "")
  if [[ -n "$RTT" ]]; then
    RTT_INT="${RTT%.*}"
    if   [[ "$RTT_INT" -le 10 ]];  then good    "${label} (${host}): ${RTT} ms"
    elif [[ "$RTT_INT" -le 50 ]];  then good    "${label} (${host}): ${RTT} ms"
    elif [[ "$RTT_INT" -le 150 ]]; then concern "${label} (${host}): ${RTT} ms — elevated latency"
    else                                bad     "${label} (${host}): ${RTT} ms — high latency"
    fi
  else
    bad "${label} (${host}): unreachable"
  fi
}

# Gateway
[[ "$ROUTER" != "unknown" ]] && ping_test "$ROUTER" "Gateway"

# External
ping_test "8.8.8.8"    "Google DNS (internet)"
ping_test "apple.com"  "Apple (DNS + internet)"
[[ -n "$CUSTOM_HOST" ]] && ping_test "$CUSTOM_HOST" "Custom host"

# ══════════════════════════════════════════════════════════════════════
# 5. RECENT DISCONNECTS (system log)
# ══════════════════════════════════════════════════════════════════════
section "Recent Wi-Fi Events (last 30 min)"

WIFI_LOG=$(log show --predicate \
  'subsystem == "com.apple.wifi" OR subsystem CONTAINS "airport"' \
  --last 30m --info 2>/dev/null | tail -30 || echo "")

if [[ -z "$WIFI_LOG" ]]; then
  info "(No Wi-Fi log entries in last 30 min, or log access restricted)"
else
  # Show only disconnect/auth events
  DISCONNECTS=$(echo "$WIFI_LOG" | grep -iE "disconnect|deauth|timeout|failed|error" \
                | grep -v "Debug\|Trace" | tail -10 || echo "")
  if [[ -n "$DISCONNECTS" ]]; then
    concern "Recent disconnect/error events:"
    echo "$DISCONNECTS" | while IFS= read -r line; do
      echo -e "     ${DIM}${line:0:120}${RESET}"
    done
  else
    good "No disconnect/error events in last 30 minutes"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 6. NEARBY NETWORKS (channel congestion)
# ══════════════════════════════════════════════════════════════════════
section "Channel Congestion (nearby networks)"

if [[ -x "$AIRPORT" ]]; then
  SCAN=$("$AIRPORT" -s 2>/dev/null | head -20 || echo "")
  if [[ -n "$SCAN" ]]; then
    info "Nearby networks (top 20):"
    echo "$SCAN" | while IFS= read -r line; do
      echo -e "     ${DIM}${line}${RESET}"
    done

    # Count how many are on same channel as us
    SAME_CHAN=$(echo "$SCAN" | awk -v ch="${CHANNEL:-0}" '$4 == ch {count++} END {print count+0}')
    if [[ "$SAME_CHAN" -gt 4 ]]; then
      bad "Channel ${CHANNEL}: ${SAME_CHAN} competing networks — significant congestion"
    elif [[ "$SAME_CHAN" -gt 2 ]]; then
      concern "Channel ${CHANNEL}: ${SAME_CHAN} competing networks"
    else
      good "Channel ${CHANNEL}: ${SAME_CHAN} competing network(s)"
    fi
  fi
else
  info "airport binary not available for channel scan"
fi

# ── Save report ───────────────────────────────────────────────────────
if [[ "$SAVE_REPORT" == "true" ]]; then
  REPORT_FILE="${HOME}/Desktop/wifi-diag-$(hostname -s)-${TIMESTAMP}.txt"
  # Re-run without colour codes and save
  if [[ -n "$CUSTOM_HOST" ]]; then
    bash "$0" --host "$CUSTOM_HOST" > "$REPORT_FILE" 2>&1 || true
  else
    bash "$0" > "$REPORT_FILE" 2>&1 || true
  fi
  echo
  info "Report saved: ${REPORT_FILE}"
fi
