#!/bin/bash
# dock_clean_v2.sh — macOS Dock reset: clear the Dock and pin only chosen apps
#
# Removes every app from the current user's Dock, adds back only the apps
# listed in DOCK_APPS, turns off "Show suggested and recent apps", clears
# the right-hand stacks/folders section, then restarts the Dock.
#
# Usage:
#   ./dock_clean_v2.sh
#   DOCK_APPS="/Applications/Safari.app:/System/Applications/Mail.app" ./dock_clean_v2.sh
#
# Run as the logged-in user (NOT with sudo — the Dock preferences being changed
# belong to whoever runs the script). For MDM/root deployment, run it in the
# user's context, e.g.: launchctl asuser <uid> sudo -u <user> ./dock_clean_v2.sh
#
# Requirements: macOS, bash 3.2+.
# WARNING: your existing Dock layout is discarded. Back it up first with:
#   defaults export com.apple.dock ~/dock-backup.plist
# and restore with:
#   defaults import com.apple.dock ~/dock-backup.plist && killall Dock

set -e

# ── Configuration ─────────────────────────────────────────────────────
# Colon-separated list of .app paths to pin, in order.
DOCK_APPS="${DOCK_APPS:-/Applications/Google Chrome.app}"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "Do not run this with sudo/as root: it would change root's Dock, not yours." >&2
    exit 1
fi

# Validate all apps exist before touching the Dock
IFS=':' read -r -a APPS <<< "$DOCK_APPS"
for app in "${APPS[@]}"; do
    if [ ! -d "$app" ]; then
        echo "App not found: $app" >&2
        echo "Install it first or adjust DOCK_APPS." >&2
        exit 1
    fi
done

echo "→ Clearing all applications from the Dock..."

# 1. Remove all persistent apps from Dock
defaults delete com.apple.dock persistent-apps 2>/dev/null || true

# 2. Add only the configured apps
for app in "${APPS[@]}"; do
    echo "→ Adding ${app##*/} to the Dock..."
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict>
            <key>tile-data</key>
            <dict>
                <key>file-data</key>
                <dict>
                    <key>_CFURLString</key>
                    <string>file://${app}/</string>
                    <key>_CFURLStringType</key>
                    <integer>15</integer>
                </dict>
            </dict>
        </dict>"
done

# 3. Disable suggested/recent apps in Dock and clear stacks/folders
echo "→ Disabling suggested and recent apps in Dock..."
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock persistent-others -array

# 4. Apply changes
echo "→ Restarting Dock to apply changes..."
killall Dock

echo ""
echo "Done! Your Dock now contains only:"
for app in "${APPS[@]}"; do
    echo "  • ${app##*/}"
done
echo ""
echo "Settings applied:"
echo "  • All other apps removed"
echo "  • Suggested/Recent apps turned OFF"
echo "  • Stacks/folders (right side of Dock) cleared"
echo ""
echo "If the Dock doesn't look right, try logging out and back in."
