#!/bin/bash
# Build a Release copy and install it as /Applications/Song Creator.app.
#
# Without a signing certificate, each build would get a new identity and macOS would forget
# the microphone permission. Signing with a fixed requirement (just the bundle ID) keeps the
# permission across reinstalls.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate -q
xcodebuild -project SongCreator.xcodeproj -scheme SongCreator -configuration Release -derivedDataPath build build -quiet

APP=build/Build/Products/Release/SongCreator.app
codesign --force --deep --sign - -r='designated => identifier "com.paulshuler.SongCreator"' "$APP"

osascript -e 'quit app "Song Creator"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Song Creator.app"
ditto "$APP" "/Applications/Song Creator.app"
open "/Applications/Song Creator.app"
echo "Installed /Applications/Song Creator.app"
