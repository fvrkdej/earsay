#!/bin/bash
# Make the download for a GitHub release: dist/Earsay-<version>.zip
# Bump CFBundleShortVersionString in Resources/Info.plist first. Sign with the same
# certificate every time, so people's permissions survive the update.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
APP="$HOME/Applications/Earsay.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p dist
OUT="dist/Earsay-$VERSION.zip"
[ -e "$OUT" ] && mv "$OUT" "$OUT.old"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Made $OUT"
shasum -a 256 "$OUT"
