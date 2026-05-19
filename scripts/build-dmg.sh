#!/usr/bin/env bash
# Build and sign a Jetline DMG. Uses andreyvit/create-dmg (the bash tool
# installed by `brew install create-dmg`), which takes a staging folder
# and copies its contents into the image.
set -euo pipefail

APP="$1"
OUT_DMG="$2"
IDENTITY="${3:-}"
APP_NAME="$(basename "$APP")"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

# Stage the .app on its own so the image only contains it + the
# /Applications shortcut create-dmg adds via --app-drop-link.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

rm -f "$OUT_DMG"

create-dmg \
    --volname "Jetline" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME" 175 190 \
    --hide-extension "$APP_NAME" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    "$OUT_DMG" \
    "$STAGE"

# Sign the DMG itself so Gatekeeper validates offline on first mount.
# Without this, users get the "downloaded from internet" prompt even when
# the .app inside is notarized + stapled.
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$OUT_DMG"
fi

echo "DMG: $OUT_DMG"
