#!/bin/bash
# Build a Release copy and install it as /Applications/Song Creator.app.
#
# Without a signing certificate, each build would get a new identity and macOS would forget
# the microphone permission. Signing with a fixed requirement (just the bundle ID) keeps the
# permission across reinstalls.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Xcode project is checked in; regenerate it only if you have XcodeGen and changed project.yml.
if command -v xcodegen >/dev/null; then xcodegen generate -q; fi
# Universal, so it runs on Apple Silicon and Intel Macs.
xcodebuild -project SongCreator.xcodeproj -scheme SongCreator -configuration Release -derivedDataPath build \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet

APP=build/Build/Products/Release/SongCreator.app
codesign --force --deep --sign - -r='designated => identifier "com.paulshuler.SongCreator"' "$APP"

# Quit the running copy and wait until it's really gone; otherwise `open` would just bring the
# old version back to the front.
osascript -e 'quit app "Song Creator"' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -f "/Applications/Song Creator.app/" >/dev/null || break
    sleep 0.5
done
pkill -f "/Applications/Song Creator.app/" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/Song Creator.app"
ditto "$APP" "/Applications/Song Creator.app"
open "/Applications/Song Creator.app"
echo "Installed /Applications/Song Creator.app (build $(date +%H:%M:%S))"
