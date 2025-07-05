#!/bin/bash

#set the default path to user Library

#Change options for the Finder
defaults write ~/Library/Preferences/com.apple.finder.plist iconSize 76

defaults write ~/Library/Preferences/com.apple.finder.plist textSize 12

# Finder SideBar
defaults write ~/Library/Preferences/.GlobalPreferences.plist NSTableViewDefaultSizeMode 3

# Zoom Settings
defaults write ~/Library/Preferences/com.apple.driver.AppleBlueToothMultitouch.trackpad.plist TrackpadPinch true

defaults write ~/Library/Preferences/com.apple.driver.AppleBlueToothMultitouch.trackpad.plist TrackpadTwoFingerDoubleTapGesture true

defaults write ~/Library/Preferences/com.apple.AppleMultitouchTrackpad.plist TrackpadPinch true

defaults write ~/Library/Preferences/com.apple.universalaccess closeVeiwZoomFactor 1

defaults write ~/Library/Preferences/com.apple.universalaccess mouseDriverCursorSize 3

#Change the size of Messages.app
defaults write ~/Library/Preferences/com.apple.iChat.plist TextSize 7

#Change the size of TextEdit Fonts
defaults write ~/Library/Containers/com.apple.TextEdit/Data/Library/Preferences/com.apple.TextEdit.plist NSFixedPitchFontSize 14

defaults write ~/Library/Containers/com.apple.TextEdit/Data/Library/Preferences/com.apple.TextEdit.plist NSFontSize 14

#Change the Minimum size of fonts in Safari
defaults write com.apple.Safari.plist com.apple.Safari.ContentPageGroupIdentifier.WebKit2MinimumFontSize 10
defaults write ~/Library/Preferences/com.apple.safari AppleAntiAliasingThreshold -int 16


#Change the Minimum size of fonts in mail
defaults write ~/Library/Preferences/com.apple.mail MinimumHTMLFontSize 14


#Set the font anti-aliasing minimum sizes, globally or per-application:
defaults write ~/Library/Preferences/.GlobalPreferences AppleSmoothFontsSizeThreshold -int 16
defaults write ~/Library/Preferences/.GlobalPreferences AppleFontSmoothing -int 0
