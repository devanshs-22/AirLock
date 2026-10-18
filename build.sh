#!/bin/zsh
# Builds AirLock.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

app=build/AirLock.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp AirLock/Info.plist "$app/Contents/Info.plist"
swiftc -O -swift-version 5 AirLock/*.swift -o "$app/Contents/MacOS/AirLock"
# Sign with your Apple Development certificate when there is one, so macOS keeps the
# Accessibility, Bluetooth and keychain permissions across rebuilds. Falls back to ad-hoc.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${identity:--}" "$app"

mkdir -p ~/Applications
rm -rf ~/Applications/AirLock.app
cp -R "$app" ~/Applications/
echo "Installed ~/Applications/AirLock.app"
