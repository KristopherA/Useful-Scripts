#!/bin/zsh

# Safely repair one macOS app by moving only its standard cache/state folders.
# Nothing is permanently deleted. No administrator access required.

emulate -L zsh
setopt pipefail null_glob
umask 077

SCRIPT_VERSION="1.0.0"
APP_TARGET=""
DRY_RUN=0
ASSUME_YES=0
RESET_PREFERENCES=0
REOPEN=1

usage() {
  cat <<'EOF'
Usage: app-repair.zsh --app APP_PATH_OR_BUNDLE_ID [options]

Examples:
  app-repair.zsh --app /Applications/Slack.app
  app-repair.zsh --app com.tinyspeck.slackmacgap --dry-run

Options:
  --app VALUE          An installed .app path or its bundle identifier.
  --reset-preferences  Also move the app's preference plist files to backup.
  --no-reopen          Do not reopen the app after repair.
  --dry-run            Show what would be moved without making changes.
  --yes                Skip the confirmation prompt.
  -h, --help           Show this help.

The script does not touch documents, cookies, keychains, account databases,
or group-container data. Moved items are kept in a timestamped backup folder.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      shift
      [[ $# -gt 0 ]] || { print -u2 "Missing value for --app"; exit 64; }
      APP_TARGET="$1"
      ;;
    --reset-preferences) RESET_PREFERENCES=1 ;;
    --no-reopen) REOPEN=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 64 ;;
  esac
  shift
done

[[ -n "$APP_TARGET" ]] || { print -u2 "--app is required"; usage >&2; exit 64; }

app_path=""
bundle_id=""
display_name=""

if [[ "$APP_TARGET" == *.app && ! -d "$APP_TARGET" ]]; then
  print -u2 "Application path does not exist: $APP_TARGET"
  exit 66
elif [[ -d "$APP_TARGET" && "$APP_TARGET" == *.app ]]; then
  app_path="${APP_TARGET:A}"
  info_plist="$app_path/Contents/Info.plist"
  [[ -f "$info_plist" ]] || { print -u2 "Not a valid application bundle: $app_path"; exit 66; }
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null)
else
  bundle_id="$APP_TARGET"
fi

if [[ ! "$bundle_id" =~ '^[A-Za-z0-9][A-Za-z0-9._-]+$' ]]; then
  print -u2 "Invalid bundle identifier: $bundle_id"
  exit 64
fi

if [[ -z "$app_path" ]]; then
  app_path=$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null | awk '/\.app(\/|$)/ {sub(/\.app\/.*/, ".app"); print; exit}')
fi

if [[ -n "$app_path" && -f "$app_path/Contents/Info.plist" ]]; then
  display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_path/Contents/Info.plist" 2>/dev/null)
  [[ -n "$display_name" ]] || display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app_path/Contents/Info.plist" 2>/dev/null)
fi
[[ -n "$display_name" ]] || display_name="${app_path:t:r}"
[[ -n "$display_name" ]] || display_name="$bundle_id"

typeset -a labels targets
labels=(
  "User cache"
  "Saved state"
  "HTTP cache"
  "Sandbox cache"
)
targets=(
  "$HOME/Library/Caches/$bundle_id"
  "$HOME/Library/Saved Application State/$bundle_id.savedState"
  "$HOME/Library/HTTPStorages/$bundle_id"
  "$HOME/Library/Containers/$bundle_id/Data/Library/Caches"
)

if (( RESET_PREFERENCES )); then
  labels+=("Preferences")
  targets+=("$HOME/Library/Preferences/$bundle_id.plist")
  for pref in "$HOME/Library/Preferences/ByHost/$bundle_id".*.plist(N); do
    labels+=("Host preferences")
    targets+=("$pref")
  done
fi

print "macOS App Repair v${SCRIPT_VERSION}"
print "Application: ${display_name}"
print "Bundle ID:   ${bundle_id}"
[[ -n "$app_path" ]] && print "App path:    ${app_path}"
print ""
print "Items found:"

found_count=0
for index in {1..${#targets}}; do
  if [[ -e "${targets[$index]}" || -L "${targets[$index]}" ]]; then
    printf '  - %-18s %s\n' "${labels[$index]}:" "${targets[$index]}"
    (( found_count++ ))
  fi
done

if (( found_count == 0 )); then
  print "  None. There are no standard repair items to move."
  exit 0
fi

if (( DRY_RUN )); then
  print ""
  print "Dry run complete; no changes were made."
  exit 0
fi

if (( ! ASSUME_YES )); then
  print ""
  print -n "Quit ${display_name} and move these items to a recoverable backup? [y/N] "
  read -r reply
  [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]] || { print "Cancelled."; exit 0; }
fi

is_running=$(osascript -e "application id \"$bundle_id\" is running" 2>/dev/null)
if [[ "$is_running" == "true" ]]; then
  print "Requesting ${display_name} to quit..."
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for attempt in {1..8}; do
    sleep 1
    is_running=$(osascript -e "application id \"$bundle_id\" is running" 2>/dev/null)
    [[ "$is_running" != "true" ]] && break
  done
  if [[ "$is_running" == "true" ]]; then
    print -u2 "The app is still running. Quit it manually, then run this repair again."
    exit 75
  fi
fi

timestamp=$(date '+%Y%m%d-%H%M%S')
backup_root="$HOME/Library/Application Support/Workstation Repair/Backups/${bundle_id}-${timestamp}"
mkdir -p -- "$backup_root" || { print -u2 "Unable to create backup folder"; exit 73; }

move_item() {
  local source="$1" label="$2" destination
  case "$source" in
    "$HOME/Library/Caches/"*|"$HOME/Library/Saved Application State/"*|"$HOME/Library/HTTPStorages/"*|"$HOME/Library/Containers/"*|"$HOME/Library/Preferences/"*) ;;
    *) print -u2 "Refusing unexpected path: $source"; return 1 ;;
  esac
  destination="$backup_root/${label// /-}--${source:t}"
  if mv -- "$source" "$destination"; then
    print "Moved: $source"
  else
    print -u2 "Could not move: $source"
    return 1
  fi
}

move_failures=0
for index in {1..${#targets}}; do
  if [[ -e "${targets[$index]}" || -L "${targets[$index]}" ]]; then
    move_item "${targets[$index]}" "${labels[$index]}" || (( move_failures++ ))
  fi
done

print ""
print "Backup: $backup_root"
if (( RESET_PREFERENCES )); then
  print "Preference changes may require signing out and back in to take full effect."
fi

if (( REOPEN )) && [[ -n "$app_path" ]]; then
  if open "$app_path"; then
    print "Reopened ${display_name}."
  else
    print -u2 "Repair finished, but the app could not be reopened."
    (( move_failures++ ))
  fi
fi

if (( move_failures > 0 )); then
  print -u2 "Repair completed with ${move_failures} warning(s)."
  exit 1
fi
print "Repair completed. If it did not help, the moved items can be restored from the backup."
