#!/usr/bin/env bash
# Build ClaudeNotch.app from the Swift package — no Xcode project needed.
# Produces ./ClaudeNotch.app, ad-hoc signed so it runs locally.
set -euo pipefail

cd "$(dirname "$0")"

# Use the full Xcode toolchain (the standalone Command Line Tools lack the
# SwiftUI macro plugins DynamicNotchKit needs).
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP="ClaudeNotch.app"
echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/ClaudeNotch"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
cp Info.plist "$APP/Contents/Info.plist"

# Validate the Info.plist before signing.
plutil -lint "$APP/Contents/Info.plist"

echo "==> ad-hoc code signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

# Register the URL scheme with Launch Services so claudenotch:// routes here.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -f "$PWD/$APP" || true

echo "==> done: $PWD/$APP"
echo "    Launch:  open '$PWD/$APP'"
echo "    For daily use: move it to /Applications and add to Login Items."
