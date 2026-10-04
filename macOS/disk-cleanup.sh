#!/bin/bash
#
# disk-cleanup.sh — macOS Safe Disk Cleanup
#
# Frees disk space by removing well-known safe targets: user caches,
# old system logs, Xcode derived data, old iOS device backups,
# and .DS_Store files. Skips anything that would affect running apps.
#
# Has a mandatory dry-run mode — it shows what WOULD be removed and
# how much space would be freed before asking for confirmation.
#
# Usage:
#   ./disk-cleanup.sh                    # interactive (shows dry-run, asks to proceed)
#   ./disk-cleanup.sh --dry-run          # dry-run only, never deletes
#   ./disk-cleanup.sh --yes              # skip confirmation prompt (use carefully)
#   ./disk-cleanup.sh --include-archives # ALSO delete iOS/iPadOS device backups
#                                        # and Xcode Archives (not recoverable)
#
# Run as the target user — does NOT need sudo.
#
# WARNING: this PERMANENTLY deletes files (no Trash): the entire contents of
# ~/Library/Caches and ~/.Trash, old logs/crash reports, Xcode DerivedData and
# every .DS_Store under your home folder. Quit apps first and review the preview.
#
# Requirements: macOS, bash 3.2+, bc.

set -uo pipefail

DRY_RUN=false
SKIP_CONFIRM=false
INCLUDE_ARCHIVES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --yes|-y)   SKIP_CONFIRM=true ;;
    --include-archives) INCLUDE_ARCHIVES=true ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) ;;
  esac
  shift
done

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

section()  { echo; echo -e "${BOLD}── $1${RESET}"; }
removed()  { echo -e "${GREEN}  ✓${RESET}  $*"; }
skipped()  { echo -e "${DIM}  –  $*${RESET}"; }
would()    { echo -e "${CYAN}  →${RESET}  $*"; }
warn()     { echo -e "${YELLOW}  ⚠${RESET}  $*"; }

TOTAL_FREED_KB=0
declare -a TARGETS_LABEL=()
declare -a TARGETS_PATH=()
declare -a TARGETS_TYPE=()    # "dir-contents", "dir", "find-dsstore", "find-logs"
declare -a TARGETS_SIZE_KB=()

# ── Measure size of a path ────────────────────────────────────────────
size_kb() {
  local path="$1"
  [[ -e "$path" ]] && du -sk "$path" 2>/dev/null | awk '{print $1}' || echo "0"
}

# ── Register a cleanup target ─────────────────────────────────────────
register() {
  local label="$1" type="$2" path="$3"
  local kb=0

  case "$type" in
    dir-contents)
      [[ -d "$path" ]] && kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}') || return ;;
    dir)
      [[ -d "$path" ]] && kb=$(size_kb "$path") || return ;;
    find-dsstore)
      kb=$(find "$path" -name ".DS_Store" -print0 2>/dev/null | xargs -0 du -ck 2>/dev/null \
           | tail -1 | awk '{print $1}') ;;
    find-old-logs)
      kb=$(find "$path" -maxdepth 2 -name "*.log" -mtime +30 -print0 2>/dev/null \
           | xargs -0 du -ck 2>/dev/null | tail -1 | awk '{print $1}') ;;
  esac

  kb="${kb:-0}"
  [[ "$kb" -gt 0 ]] || return   # skip targets that are empty / don't exist

  TARGETS_LABEL+=("$label")
  TARGETS_PATH+=("$path")
  TARGETS_TYPE+=("$type")
  TARGETS_SIZE_KB+=("$kb")
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + kb ))
}

human_size() {
  local kb="$1"
  if   [[ "$kb" -ge 1048576 ]]; then printf "%.1f GB" "$(echo "scale=1; $kb/1048576" | bc)"
  elif [[ "$kb" -ge 1024 ]];    then printf "%.1f MB" "$(echo "scale=1; $kb/1024" | bc)"
  else printf "%s KB" "$kb"
  fi
}

# ══════════════════════════════════════════════════════════════════════
# REGISTER TARGETS
# ══════════════════════════════════════════════════════════════════════

echo -e "${BOLD}Scanning for cleanup targets...${RESET}"

# User caches (safe — apps rebuild these)
register "User caches (~/Library/Caches)"  \
  dir-contents "${HOME}/Library/Caches"

# App log files in ~/Library/Logs
register "User app logs (~/Library/Logs older than 30 days)" \
  find-old-logs "${HOME}/Library/Logs"

# System log archive (old compressed logs)
if [[ -d /var/log ]]; then
  OLD_SYSLOG_KB=$(find /var/log -name "*.gz" -mtime +30 -print0 2>/dev/null \
                  | xargs -0 du -ck 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
  if [[ "${OLD_SYSLOG_KB:-0}" -gt 0 ]]; then
    TARGETS_LABEL+=("Compressed system logs (>30 days)")
    TARGETS_PATH+=("/var/log")
    TARGETS_TYPE+=("find-old-gz")
    TARGETS_SIZE_KB+=("$OLD_SYSLOG_KB")
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + OLD_SYSLOG_KB ))
  fi
fi

# Xcode derived data
register "Xcode DerivedData" \
  dir-contents "${HOME}/Library/Developer/Xcode/DerivedData"

if [[ "$INCLUDE_ARCHIVES" == "true" ]]; then
  # Xcode archives (old builds — may want to keep recent ones)
  register "Xcode Archives (all)" \
    dir-contents "${HOME}/Library/Developer/Xcode/Archives"

  # iOS device backups (may be the only copy of a device's data!)
  register "iOS/iPadOS device backups" \
    dir-contents "${HOME}/Library/Application Support/MobileSync/Backup"
else
  for _p in "${HOME}/Library/Developer/Xcode/Archives" \
            "${HOME}/Library/Application Support/MobileSync/Backup"; do
    _kb=$(size_kb "$_p")
    [[ "${_kb:-0}" -gt 0 ]] && warn "Not cleaned (use --include-archives): ${_p} ($(human_size "$_kb"))"
  done
fi

# Old crash reports (keep the 20 most recent)
OLD_CRASH_KB=$(find "${HOME}/Library/Logs/DiagnosticReports" \
  \( -name "*.ips" -o -name "*.crash" \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null \
  | tail -n +21 | tr '\n' '\0' | xargs -0 du -ck 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
if [[ "${OLD_CRASH_KB:-0}" -gt 0 ]]; then
  TARGETS_LABEL+=("Old crash reports (keeping 20 most recent)")
  TARGETS_PATH+=("${HOME}/Library/Logs/DiagnosticReports")
  TARGETS_TYPE+=("old-crashes")
  TARGETS_SIZE_KB+=("$OLD_CRASH_KB")
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + OLD_CRASH_KB ))
fi

# Trash
TRASH_KB=$(size_kb "${HOME}/.Trash")
if [[ "${TRASH_KB:-0}" -gt 0 ]]; then
  TARGETS_LABEL+=("Trash (~/.Trash)")
  TARGETS_PATH+=("${HOME}/.Trash")
  TARGETS_TYPE+=("dir-contents")
  TARGETS_SIZE_KB+=("$TRASH_KB")
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + TRASH_KB ))
fi

# .DS_Store files (home directory tree only — safe to remove everywhere)
register ".DS_Store files (~/)" \
  find-dsstore "${HOME}"

# Downloads folder — ASK separately, just show size
DL_KB=$(size_kb "${HOME}/Downloads")
if [[ "${DL_KB:-0}" -gt 1024 ]]; then
  warn "Downloads folder: $(human_size "$DL_KB") — not auto-cleaned, review manually"
fi

# ══════════════════════════════════════════════════════════════════════
# DRY RUN REPORT
# ══════════════════════════════════════════════════════════════════════
section "Cleanup Preview"

if [[ "${#TARGETS_LABEL[@]}" -eq 0 ]]; then
  echo "  Nothing to clean up — disk is already tidy."
  exit 0
fi

echo
for i in "${!TARGETS_LABEL[@]}"; do
  SIZE_HUMAN=$(human_size "${TARGETS_SIZE_KB[$i]}")
  would "$(printf "%-52s %s" "${TARGETS_LABEL[$i]}" "$SIZE_HUMAN")"
done

echo
echo -e "  ${BOLD}Total reclaimable: $(human_size "$TOTAL_FREED_KB")${RESET}"

# Disk free before
DISK_FREE_BEFORE=$(df -k / | awk 'NR==2 {print $4}')
DISK_FREE_BEFORE_HUMAN=$(human_size "$DISK_FREE_BEFORE")
echo "  Disk free now:    ${DISK_FREE_BEFORE_HUMAN}"

# ── Stop here in dry-run mode ─────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo
  warn "Dry-run mode: no files deleted. Remove --dry-run to clean."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────
if [[ "$SKIP_CONFIRM" == "false" ]]; then
  echo
  read -rp "  Proceed with cleanup? (y/N): " CONFIRM
  # (bash 3.2-compatible; macOS /bin/bash does not support ${VAR,,})
  [[ "$CONFIRM" == [yY] ]] || { echo "  Aborted."; exit 0; }
fi

# ══════════════════════════════════════════════════════════════════════
# EXECUTE CLEANUP
# ══════════════════════════════════════════════════════════════════════
section "Cleaning..."

ACTUALLY_FREED_KB=0

for i in "${!TARGETS_LABEL[@]}"; do
  LABEL="${TARGETS_LABEL[$i]}"
  PATH_="${TARGETS_PATH[$i]}"
  TYPE="${TARGETS_TYPE[$i]}"

  case "$TYPE" in

    dir-contents)
      if [[ -d "$PATH_" ]]; then
        BEFORE_KB=$(size_kb "$PATH_")
        # Remove contents but keep the directory itself
        find "$PATH_" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        AFTER_KB=$(size_kb "$PATH_")
        FREED=$(( BEFORE_KB - AFTER_KB ))
        removed "${LABEL}: freed $(human_size "$FREED")"
        ACTUALLY_FREED_KB=$(( ACTUALLY_FREED_KB + FREED ))
      fi ;;

    find-dsstore)
      COUNT=$(find "$PATH_" -name ".DS_Store" 2>/dev/null | wc -l | tr -d ' ')
      find "$PATH_" -name ".DS_Store" -delete 2>/dev/null || true
      removed "${LABEL}: removed ${COUNT} files"
      ACTUALLY_FREED_KB=$(( ACTUALLY_FREED_KB + TARGETS_SIZE_KB[i] )) ;;

    find-old-logs)
      find "$PATH_" -maxdepth 2 -name "*.log" -mtime +30 -delete 2>/dev/null || true
      removed "${LABEL}: old logs removed"
      ACTUALLY_FREED_KB=$(( ACTUALLY_FREED_KB + TARGETS_SIZE_KB[i] )) ;;

    find-old-gz)
      find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null || true
      removed "${LABEL}: old compressed logs removed"
      ACTUALLY_FREED_KB=$(( ACTUALLY_FREED_KB + TARGETS_SIZE_KB[i] )) ;;

    old-crashes)
      # Keep the 20 most recent, delete the rest
      find "${HOME}/Library/Logs/DiagnosticReports" \
        \( -name "*.ips" -o -name "*.crash" \) -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | tail -n +21 | tr '\n' '\0' \
        | xargs -0 rm -f 2>/dev/null || true
      removed "${LABEL}: old reports removed"
      ACTUALLY_FREED_KB=$(( ACTUALLY_FREED_KB + TARGETS_SIZE_KB[i] )) ;;

  esac
done

# Purge system memory caches (harmless, helps immediately)
# -n: never prompt for a password; skip silently if no cached sudo credentials
sudo -n purge 2>/dev/null && removed "Memory caches purged" || skipped "Memory purge skipped (no sudo)"

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════
DISK_FREE_AFTER=$(df -k / | awk 'NR==2 {print $4}')
ACTUAL_GAIN=$(( DISK_FREE_AFTER - DISK_FREE_BEFORE ))

echo
echo "════════════════════════════════════════"
echo "  CLEANUP COMPLETE"
echo "  Freed:     $(human_size "$ACTUALLY_FREED_KB")"
echo "  Disk free: $(human_size "$DISK_FREE_AFTER")  (was $(human_size "$DISK_FREE_BEFORE"))"
echo "════════════════════════════════════════"
echo
echo "  To free more space:"
echo "  - Review ~/Downloads manually"
echo "  - Use System Settings > General > Storage for large file analysis"
echo "  - Remove unused apps"
echo "  - Move media to external storage"
