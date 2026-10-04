#!/bin/bash
#
# slow-mac-triage.sh — macOS Slow Mac Diagnostics
#
# Diagnoses common causes of slow Macs without requiring MDM or
# third-party tools. Covers CPU, memory, disk, startup items,
# kernel panics, Spotlight, and swap pressure.
#
# Usage:
#   ./slow-mac-triage.sh           # current user context
#   sudo ./slow-mac-triage.sh      # full detail (more startup items, etc.)
#
# Output is printed to the terminal and saved to ~/Desktop/slow-mac-*.txt
#
# Requirements: macOS, bash 3.2+, built-in tools only. Read-only.

set -uo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${HOME}/Desktop"; [[ -d "$REPORT_DIR" ]] || REPORT_DIR="$HOME"
REPORT_FILE="${REPORT_DIR}/slow-mac-triage-$(hostname -s)-${TIMESTAMP}.txt"

# ── Colour helpers ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

_log() { echo -e "$1" | tee -a "$REPORT_FILE"; }
good()    { _log "${GREEN}  ✓${RESET}  $*"; }
concern() { _log "${YELLOW}  ⚠${RESET}  $*"; }
bad()     { _log "${RED}  ✗${RESET}  $*"; }
info()    { _log "${CYAN}  ℹ${RESET}  $*"; }
section() { _log ""; _log "${BOLD}── $1${RESET}"; }
raw()     { _log "${DIM}     $*${RESET}"; }

IS_ROOT=false; [[ "${EUID}" -eq 0 ]] && IS_ROOT=true
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "$USER")

{
  echo "════════════════════════════════════════"
  echo "  Slow Mac Triage"
  echo "  Host:  $(hostname)"
  echo "  User:  ${CONSOLE_USER}"
  echo "  macOS: $(sw_vers -productVersion)"
  echo "  Date:  $(date)"
  echo "════════════════════════════════════════"
} | tee "$REPORT_FILE"

# ══════════════════════════════════════════════════════════════════════
# 1. CPU PRESSURE
# ══════════════════════════════════════════════════════════════════════
section "1. CPU"

# Top 5 CPU consumers right now (sample for 2 seconds)
TOP_OUT=$(top -l 2 -s 1 -n 10 -o cpu -stats pid,command,cpu 2>/dev/null | tail -15)

# CPU idle from last top sample
CPU_IDLE=$(echo "$TOP_OUT" | grep "CPU usage" | tail -1 \
           | grep -oE '[0-9]+\.[0-9]+% idle' | grep -oE '[0-9]+\.[0-9]+' || echo "")
CPU_USER=$(echo "$TOP_OUT" | grep "CPU usage" | tail -1 \
           | grep -oE '[0-9]+\.[0-9]+% user' | grep -oE '[0-9]+\.[0-9]+' || echo "")
CPU_SYS=$(echo  "$TOP_OUT" | grep "CPU usage" | tail -1 \
           | grep -oE '[0-9]+\.[0-9]+% sys'  | grep -oE '[0-9]+\.[0-9]+' || echo "")

if [[ -n "$CPU_IDLE" ]]; then
  CPU_IDLE_INT="${CPU_IDLE%.*}"
  if   [[ "$CPU_IDLE_INT" -ge 50 ]]; then good    "CPU idle: ${CPU_IDLE}%  (user: ${CPU_USER}%  sys: ${CPU_SYS}%)"
  elif [[ "$CPU_IDLE_INT" -ge 20 ]]; then concern "CPU idle: ${CPU_IDLE}%  — moderate load (user: ${CPU_USER}%  sys: ${CPU_SYS}%)"
  else                                    bad     "CPU idle: ${CPU_IDLE}%  — high load (user: ${CPU_USER}%  sys: ${CPU_SYS}%)"
  fi
else
  info "CPU stats unavailable"
fi

# Top processes by CPU
_log ""
_log "  ${DIM}Top processes by CPU:${RESET}"
echo "$TOP_OUT" | grep -v "^$\|CPU usage\|Processes\|Load\|SharedLibs\|MemRegions\|PhysMem\|VM\|Networks\|Disks\|PID" \
  | head -8 | while read -r line; do raw "$line"; done

# Thermal state
THERMAL=$(pmset -g therm 2>/dev/null | grep -i "cpu_speed_limit\|CPU_Scheduler_Limit" | head -2 || echo "")
if [[ -n "$THERMAL" ]]; then
  LIMIT=$(echo "$THERMAL" | grep -oE '[0-9]+' | head -1)
  if [[ "${LIMIT:-100}" -lt 100 ]]; then
    bad "Thermal throttling detected: CPU limited to ${LIMIT}% — check vents/cooling"
  else
    good "No thermal throttling"
  fi
else
  good "No thermal throttling detected"
fi

# ══════════════════════════════════════════════════════════════════════
# 2. MEMORY PRESSURE
# ══════════════════════════════════════════════════════════════════════
section "2. Memory"

# Physical RAM
RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
info "Physical RAM: ${RAM_GB} GB"

# Memory pressure level (kernel level: 1=normal, 2=warn, 4=critical)
case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
  1) MEM_PRESSURE="NORMAL" ;;
  2) MEM_PRESSURE="WARN" ;;
  4) MEM_PRESSURE="CRITICAL" ;;
  *) MEM_PRESSURE=$(memory_pressure 2>/dev/null | grep "System-wide memory pressure" \
                    | grep -oE "CRITICAL|WARN|NORMAL" || echo "UNKNOWN") ;;
esac
case "$MEM_PRESSURE" in
  NORMAL)   good    "Memory pressure: NORMAL" ;;
  WARN)     concern "Memory pressure: WARN — system is paging; close unused apps" ;;
  CRITICAL) bad     "Memory pressure: CRITICAL — severe paging, strong cause of slowness" ;;
  *)        info    "Memory pressure: ${MEM_PRESSURE}" ;;
esac

# vm_stat — page-outs and swapins are the key slow indicators
VM=$(vm_stat 2>/dev/null)
PAGE_SIZE=$(echo "$VM" | awk '/page size/ {print $8}')
PAGE_SIZE="${PAGE_SIZE:-4096}"
PAGEOUTS=$(echo   "$VM" | awk '/^Swapouts:/ {gsub(/\./,"",$NF); print $NF}')
PAGEINS=$(echo    "$VM" | awk '/^Swapins:/  {gsub(/\./,"",$NF); print $NF}')
WIRED=$(echo      "$VM" | awk '/Pages wired down/  {gsub(/\./,"",$NF); print $NF}')
FREE=$(echo       "$VM"  | awk '/Pages free/        {gsub(/\./,"",$NF); print $NF}')

PAGEOUT_MB=$(( ${PAGEOUTS:-0} * PAGE_SIZE / 1024 / 1024 ))
PAGEIN_MB=$(( ${PAGEINS:-0}   * PAGE_SIZE / 1024 / 1024 ))
FREE_MB=$(( ${FREE:-0}        * PAGE_SIZE / 1024 / 1024 ))

if   [[ "$PAGEOUT_MB" -gt 500 ]]; then bad     "Swap written: ${PAGEOUT_MB} MB  (strong indicator of memory pressure)"
elif [[ "$PAGEOUT_MB" -gt 100 ]]; then concern "Swap written: ${PAGEOUT_MB} MB"
else                                   good    "Swap written: ${PAGEOUT_MB} MB  (normal)"
fi
info "Swap read: ${PAGEIN_MB} MB  |  Free pages: ${FREE_MB} MB"

# Swap file size
SWAP_SIZE=$(sysctl -n vm.swapusage 2>/dev/null \
            | grep -oE 'used = [0-9.]+[MGK]' | awk '{print $3}' || echo "N/A")
info "Swap currently in use: ${SWAP_SIZE}"

# ══════════════════════════════════════════════════════════════════════
# 3. DISK
# ══════════════════════════════════════════════════════════════════════
section "3. Disk"

# Capacity
DISK_USED=$(df -H / | awk 'NR==2 {print $3}')
DISK_AVAIL=$(df -H / | awk 'NR==2 {print $4}')
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if   [[ "${DISK_PCT:-0}" -ge 95 ]]; then bad     "Disk: ${DISK_PCT}% full (${DISK_AVAIL} free) — critically low, strong cause of slowness"
elif [[ "${DISK_PCT:-0}" -ge 85 ]]; then concern "Disk: ${DISK_PCT}% full (${DISK_AVAIL} free) — consider running disk-cleanup.sh"
else                                     good    "Disk: ${DISK_PCT}% full (${DISK_AVAIL} free, ${DISK_USED} used)"
fi

# SMART status
SMART=$(diskutil info disk0 2>/dev/null | awk '/SMART Status/ {print $NF}' || echo "N/A")
if echo "$SMART" | grep -qi "Verified"; then
  good "SMART: Verified"
elif echo "$SMART" | grep -qi "Not Supported"; then
  info "SMART: Not supported (Apple Silicon / NVMe)"
else
  bad  "SMART: ${SMART} — possible disk issue"
fi

# Disk I/O (iostat averages since boot; columns are KB/t, tps, MB/s)
IO_STATS=$(iostat -d disk0 2>/dev/null | awk 'NR==3 && NF>=3 {print $1" KB/t, "$2" tps, "$3" MB/s"}' || echo "")
[[ -n "$IO_STATS" ]] && info "Disk I/O (avg since boot): ${IO_STATS}"

# Spotlight indexing
SPOTLIGHT=$(mdutil -s / 2>/dev/null || echo "unknown")
if echo "$SPOTLIGHT" | grep -qi "indexing enabled"; then
  if echo "$SPOTLIGHT" | grep -qi "currently being indexed"; then
    concern "Spotlight: currently indexing — will slow the machine temporarily"
  else
    good "Spotlight: indexed and ready"
  fi
elif echo "$SPOTLIGHT" | grep -qi "disabled"; then
  info "Spotlight: disabled on /"
else
  info "Spotlight: ${SPOTLIGHT}"
fi

# Time Machine backup status
TM_RUNNING=$(tmutil status 2>/dev/null | grep -c "Running = 1" || true)
if [[ "$TM_RUNNING" -gt 0 ]]; then
  concern "Time Machine: backup in progress — this adds disk load"
else
  good "Time Machine: no backup in progress"
fi

# ══════════════════════════════════════════════════════════════════════
# 4. STARTUP ITEMS COUNT
# ══════════════════════════════════════════════════════════════════════
section "4. Startup Items"

count_items() {
  local dir="$1"
  [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ' || echo "0"
}

SYS_DAEMONS=$(count_items /Library/LaunchDaemons)
SYS_AGENTS=$(count_items  /Library/LaunchAgents)
USR_AGENTS=0

if [[ "$IS_ROOT" == "true" ]]; then
  for UDIR in /Users/*/Library/LaunchAgents; do
    N=$(count_items "$UDIR")
    USR_AGENTS=$(( USR_AGENTS + N ))
  done
else
  USR_AGENTS=$(count_items "${HOME}/Library/LaunchAgents")
fi

TOTAL_ITEMS=$(( SYS_DAEMONS + SYS_AGENTS + USR_AGENTS ))
info "/Library/LaunchDaemons: ${SYS_DAEMONS}  |  /Library/LaunchAgents: ${SYS_AGENTS}  |  ~/Library/LaunchAgents: ${USR_AGENTS}"

if   [[ "$TOTAL_ITEMS" -gt 60 ]]; then bad     "Startup items total: ${TOTAL_ITEMS} — unusually high, run startup-items-audit.sh"
elif [[ "$TOTAL_ITEMS" -gt 40 ]]; then concern "Startup items total: ${TOTAL_ITEMS} — elevated, consider reviewing"
else                                   good    "Startup items total: ${TOTAL_ITEMS}"
fi

# Login items for current/console user (launchctl)
LOGIN_ITEMS=$(osascript -e \
  'tell application "System Events" to get the name of every login item' \
  2>/dev/null | tr ',' '\n' | grep -v '^$' | wc -l | tr -d ' ')
if [[ "${LOGIN_ITEMS:-0}" -gt 10 ]]; then
  concern "Login items: ${LOGIN_ITEMS} — consider removing unused ones in System Settings > General > Login Items"
elif [[ "${LOGIN_ITEMS:-0}" -gt 0 ]]; then
  info "Login items: ${LOGIN_ITEMS}"
fi

# ══════════════════════════════════════════════════════════════════════
# 5. KERNEL PANICS
# ══════════════════════════════════════════════════════════════════════
section "5. Kernel Panics"

PANIC_DIR="/Library/Logs/DiagnosticReports"
# Older macOS writes *.panic; newer releases write panic-full-*.ips / panic-base-*.ips
RECENT_PANICS=$(find "$PANIC_DIR" \( -name "*.panic" -o -name "panic-*.ips" \) -mtime -30 \
  2>/dev/null | wc -l | tr -d ' ')

TOTAL_PANICS=$(find "$PANIC_DIR" \( -name "*.panic" -o -name "panic-*.ips" \) 2>/dev/null | wc -l | tr -d ' ')

if [[ "$RECENT_PANICS" -gt 3 ]]; then
  bad "Kernel panics (last 30 days): ${RECENT_PANICS} — hardware or driver issue likely"
elif [[ "$RECENT_PANICS" -gt 0 ]]; then
  concern "Kernel panics (last 30 days): ${RECENT_PANICS}"
else
  good "No kernel panics in the last 30 days"
fi

[[ "$TOTAL_PANICS" -gt 0 ]] && info "Total panic files on disk: ${TOTAL_PANICS}"

# Most recent panic (if any)
LAST_PANIC=$(find "$PANIC_DIR" \( -name "*.panic" -o -name "panic-*.ips" \) -print0 2>/dev/null \
             | xargs -0 ls -t 2>/dev/null | head -1 || echo "")
if [[ -n "$LAST_PANIC" ]]; then
  PANIC_DATE=$(stat -f "%Sm" -t "%Y-%m-%d" "$LAST_PANIC" 2>/dev/null || echo "unknown")
  PANIC_REASON=$(grep -m1 "^panic(" "$LAST_PANIC" 2>/dev/null | head -c 120 || echo "see file")
  info "Most recent panic: ${PANIC_DATE} — ${LAST_PANIC##*/}"
  [[ -n "$PANIC_REASON" ]] && raw "$PANIC_REASON"
fi

# ══════════════════════════════════════════════════════════════════════
# 6. RECENT HIGH-IMPACT CRASHES
# ══════════════════════════════════════════════════════════════════════
section "6. App Crashes (last 7 days)"

USER_REPORTS="${HOME}/Library/Logs/DiagnosticReports"
CRASH_COUNT=$(find "$USER_REPORTS" \( -name "*.ips" -o -name "*.crash" \) -mtime -7 2>/dev/null \
  | wc -l | tr -d ' ')
CRASH_COUNT="${CRASH_COUNT:-0}"

if [[ "$CRASH_COUNT" -gt 10 ]]; then
  bad "App crashes last 7 days: ${CRASH_COUNT} — check ~/Library/Logs/DiagnosticReports"
elif [[ "$CRASH_COUNT" -gt 3 ]]; then
  concern "App crashes last 7 days: ${CRASH_COUNT}"
else
  good "App crashes last 7 days: ${CRASH_COUNT:-0}"
fi

# ══════════════════════════════════════════════════════════════════════
# 7. NETWORK (background activity)
# ══════════════════════════════════════════════════════════════════════
section "7. Background Network Activity"

# Active connections count
CONN_COUNT=$(netstat -an 2>/dev/null | grep -c ESTABLISHED || true)
info "Established network connections: ${CONN_COUNT}"

if [[ "$CONN_COUNT" -gt 100 ]]; then
  concern "High number of connections — could indicate sync/cloud activity"
fi

# ══════════════════════════════════════════════════════════════════════
# 8. UPTIME
# ══════════════════════════════════════════════════════════════════════
section "8. Uptime"

UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*//')
BOOT_TIME=$(sysctl -n kern.boottime 2>/dev/null \
            | awk '{print $4}' | tr -d ',' || echo "")
info "Uptime: ${UPTIME}"

UPTIME_DAYS=$(uptime | grep -oE '[0-9]+ day' | awk '{print $1}' || echo "0")
if [[ "${UPTIME_DAYS:-0}" -gt 30 ]]; then
  bad "Machine has been running ${UPTIME_DAYS} days — restart strongly recommended"
elif [[ "${UPTIME_DAYS:-0}" -gt 14 ]]; then
  concern "Machine has been running ${UPTIME_DAYS} days — a restart may help clear memory/swap"
fi

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════
{
  echo ""
  echo "════════════════════════════════════════"
  echo "  TRIAGE COMPLETE"
  echo "  Full report: ${REPORT_FILE}"
  echo "════════════════════════════════════════"
  echo "  Quick fixes to try:"
  echo "  1. Restart the Mac (clears memory/swap)"
  echo "  2. Run: ./disk-cleanup.sh (free disk space)"
  echo "  3. Run: ./startup-items-audit.sh (review launch items)"
  echo "  4. System Settings > General > Login Items → remove unused"
  echo "  5. Activity Monitor → sort by CPU or Memory"
  echo "════════════════════════════════════════"
} | tee -a "$REPORT_FILE"
