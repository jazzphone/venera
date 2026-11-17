#!/bin/bash
# build-helper: build/Venera.app (x86_64, macOS 26), the guest's helper app (helper/Venera), ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
A=build/Venera.app
rm -rf "$A" build/Venera.iconset && mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -fobjc-arc -fmodules \
  -framework Cocoa -framework IOKit -framework UserNotifications \
  -o "$A/Contents/MacOS/Venera" helper/Venera/main.m
sed "s/VERSION/$VERSION/g" helper/Venera/Info.plist > "$A/Contents/Info.plist"
xcrun clang -fobjc-arc -fmodules -framework Cocoa -o build/makeicon helper/makeicon.m
build/makeicon build/Venera.iconset
iconutil -c icns -o "$A/Contents/Resources/Venera.icns" build/Venera.iconset
codesign -s - --force --timestamp=none "$A" >/dev/null 2>&1
echo "$A ($VERSION)"
