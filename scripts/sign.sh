#!/usr/bin/env bash
# Inside-out Developer ID signing for Jetline.app with embedded Sparkle.framework.
# Order matters: nested binaries → framework → main exec → bundle. NEVER --deep
# (overwrites the XPC services' entitlements). Hardened runtime via `-o runtime`.
set -euo pipefail

APP="$1"
IDENTITY="$2"
ENTS="$3"

FW="$APP/Contents/Frameworks/Sparkle.framework"

if [ ! -d "$FW" ]; then
    echo "Sparkle.framework not found at $FW"
    exit 1
fi

echo "Signing Sparkle XPC services and helpers…"
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    "$FW/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    "$FW/Versions/B/Autoupdate"
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    "$FW/Versions/B/Updater.app"

echo "Signing Sparkle.framework…"
codesign -f -s "$IDENTITY" -o runtime --timestamp "$FW"

echo "Signing main executable…"
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTS" \
    "$APP/Contents/MacOS/jetline"

echo "Signing app bundle…"
codesign -f -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTS" \
    "$APP"

echo "Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed: $APP"
