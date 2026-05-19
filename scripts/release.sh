#!/usr/bin/env bash
# End-to-end local release. Use for the first release before CI is wired
# or when GitHub Actions is broken.
#
# Required env (all secrets):
#   APPLE_ID                     apple id email
#   APPLE_TEAM_ID                10-char team identifier
#   APPLE_APP_SPECIFIC_PWD       app-specific password from appleid.apple.com
#
# Optional env:
#   SKIP_APPCAST=1   skip appcast generation/publish (e.g. very first release)
#   SKIP_PUBLISH=1   build + notarize but don't tag / push / publish
#
# Pre-flight (one-time):
#   xcrun notarytool store-credentials jetline-notary \
#     --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PWD"
#   brew install create-dmg
set -euo pipefail

: "${APPLE_ID:?missing}"
: "${APPLE_TEAM_ID:?missing}"
: "${APPLE_APP_SPECIFIC_PWD:?missing}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" BundleResources/Info.plist)
BUILD=$(git rev-list --count HEAD)

echo "Releasing v$VERSION (build $BUILD)"

# Bump CFBundleVersion to the commit count (Sparkle compares on this).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" BundleResources/Info.plist

# Build, sign, DMG, notarize, staple.
make release

DMG="dist/Jetline-$VERSION.dmg"

if [ -n "${SKIP_PUBLISH:-}" ]; then
    echo "SKIP_PUBLISH set — leaving artifacts in dist/"
    exit 0
fi

# Commit the build-number bump and tag.
git add BundleResources/Info.plist
git commit -m "Release $VERSION (build $BUILD)" || true
git tag "v$VERSION" 2>/dev/null || true
git push origin HEAD --tags

# Publish a GitHub release with the DMG.
gh release create "v$VERSION" "$DMG" \
    --title "Jetline $VERSION" \
    --generate-notes

if [ -z "${SKIP_APPCAST:-}" ]; then
    mkdir -p releases
    cp "$DMG" releases/
    ./scripts/generate-appcast.sh ./releases
    ./scripts/publish-appcast.sh
fi

echo "Done: v$VERSION"
