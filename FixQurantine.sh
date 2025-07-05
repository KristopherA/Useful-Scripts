#!/bin/bash

xattr -d com.apple.quarantine /Library/Application\ Support/Scripts/remove-word-linkcreation.sh

launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.example.remove-word-linkcreation.plist
