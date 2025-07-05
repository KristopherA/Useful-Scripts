#!/bin/bash

xattr -d com.apple.quarantine /Library/Application\ Support/UNA/UNAMacPDFM.sh

launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/ca.una.MACPDFM.plist
