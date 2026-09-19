#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DockVU.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.4" \
  -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/DockVU" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework CoreMediaIO -framework Combine
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/MeterView.swift" "$ROOT/scripts/Icon.swift" -o "$ROOT/build/make-icon" -framework AppKit
"$ROOT/build/make-icon" "$ROOT/build"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${DOCKVU_SIGN_IDENTITY:--}" "$APP"
printf 'Built %s\n' "$APP"
