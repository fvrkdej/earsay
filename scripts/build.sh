#!/bin/bash
# Build the app and install it at ~/Applications/Earsay.app (always the same place,
# always signed with "Read Aloud Dev", so permissions stick).
set -euo pipefail
cd "$(dirname "$0")/.."
nice -n 19 swift build -c release -j 4
APP="$HOME/Applications/Earsay.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Swap the program in as a new file (copy beside it, then rename) instead of writing over it:
# overwriting the file of a running app in place can crash it mid-read.
cp .build/release/ReadAloud "$APP/Contents/MacOS/ReadAloud.new"
mv -f "$APP/Contents/MacOS/ReadAloud.new" "$APP/Contents/MacOS/ReadAloud"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon: an Icon Composer icon (Resources/AppIcon.icon) compiled into Assets.car, so it
# follows the Mac's icon style (Default, Dark, Clear, Tinted). AppIcon.icns is for older macOS.
# Compiling it needs Xcode 26 or later; without it, the plain AppIcon.icns is used.
mkdir -p .build/icon
if xcrun actool Resources/AppIcon.icon --compile .build/icon --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist .build/icon/partial.plist > /dev/null 2>&1; then
    cp .build/icon/Assets.car .build/icon/AppIcon.icns "$APP/Contents/Resources/"
else
    echo "Note: Xcode 26+ not found, using the plain icon (no dark or tinted styles)."
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
codesign --force --sign "Read Aloud Dev" --identifier io.autimized.readaloud "$APP"
codesign --verify --verbose "$APP" && echo "Built and signed: $APP"
