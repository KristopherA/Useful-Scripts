#!/bin/bash
#
# clean_user_data.sh - Clear the current user's data on a shared/loaner Mac
#
# Removes caches, browser history/cookies/local storage (Safari, Chrome,
# Firefox), general web data, user logs, recent items, saved application
# state, Trash, and ALL files in ~/Downloads and ~/Desktop.
#
# WARNING: This permanently deletes data. Run it as the user whose data
# should be cleared (not with sudo). Quit browsers and apps first.
#
# Usage:
#   ./clean_user_data.sh --dry-run   # list what would be deleted, change nothing
#   ./clean_user_data.sh             # asks for confirmation, then deletes
#   ./clean_user_data.sh --yes       # no prompt (for automation)
#
# Requirements: macOS, bash.

DRY_RUN=false
ASSUME_YES=false
for ARG in "$@"; do
  case "$ARG" in
    -n|--dry-run) DRY_RUN=true ;;
    -y|--yes)     ASSUME_YES=true ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $ARG" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  echo "Refusing to run as root: run as the user whose data should be cleared." >&2
  exit 1
fi

# Remove each existing path given; in dry-run mode just list them.
remove() {
  local p
  for p in "$@"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] would remove: $p"
    else
      rm -rf "$p"
    fi
  done
}

clear_default() {
  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] would run: defaults delete $1 $2"
  else
    defaults delete "$1" "$2" >/dev/null 2>&1
  fi
}

echo "This will permanently delete browsing data, caches, logs, Trash,"
echo "and everything in ~/Downloads and ~/Desktop for user: $(id -un)"
if [ "$DRY_RUN" = false ] && [ "$ASSUME_YES" = false ]; then
  read -rp "Type YES to continue: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }
fi

echo "Starting cleanup process..."

# Clear user caches
echo "Clearing user caches..."
remove ~/Library/Caches/*

# Clear browser histories and data
echo "Clearing browser histories and data..."

# Safari
echo "Clearing Safari history and data..."
remove ~/Library/Safari/History.db \
       ~/Library/Safari/History.db-lock \
       ~/Library/Safari/History.db-shm \
       ~/Library/Safari/History.db-wal \
       ~/Library/Safari/LocalStorage \
       ~/Library/Safari/Databases

# Chrome
echo "Clearing Chrome history and data..."
CHROME_DEFAULT=~/Library/Application\ Support/Google/Chrome/Default
remove "$CHROME_DEFAULT/History" \
       "$CHROME_DEFAULT/History-journal" \
       "$CHROME_DEFAULT/History Provider Cache" \
       "$CHROME_DEFAULT/Cookies" \
       "$CHROME_DEFAULT/Cookies-journal" \
       "$CHROME_DEFAULT/Local Storage" \
       "$CHROME_DEFAULT/Session Storage"

# Firefox (removes cache, history, cookies)
echo "Clearing Firefox cache, history, and data..."
for profile in ~/Library/Application\ Support/Firefox/Profiles/*; do
    if [ -d "$profile" ]; then
        remove "$profile/cache2" \
               "$profile/places.sqlite" \
               "$profile/places.sqlite-wal" \
               "$profile/places.sqlite-shm" \
               "$profile/cookies.sqlite" \
               "$profile/storage"
    fi
done

# Clear general web data
echo "Clearing general web data..."
remove ~/Library/Cookies/*
remove ~/Library/WebKit/*

# Clear user logs
echo "Clearing user logs..."
remove ~/Library/Logs/*

# Clear recent items
echo "Clearing recent items..."
clear_default com.apple.recentitems RecentDocuments
clear_default com.apple.recentitems RecentApplications
clear_default com.apple.recentitems RecentServers

# Clear saved application states (optional, may affect app behavior)
echo "Clearing saved application states..."
remove ~/Library/Saved\ Application\ State/*

# Empty Trash
echo "Emptying Trash..."
remove ~/.Trash/*

# Remove files from Downloads
echo "Removing files from Downloads..."
remove ~/Downloads/*

# Remove files from Desktop
echo "Removing files from Desktop..."
remove ~/Desktop/*

if [ "$DRY_RUN" = true ]; then
  echo "Dry run complete. Nothing was deleted."
else
  echo "Cleanup complete. Please restart your browser(s) and applications if they were open."
fi
