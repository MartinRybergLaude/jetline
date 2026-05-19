#!/usr/bin/env bash
# Run Sparkle's `generate_appcast` against a folder of update archives.
#
# In CI, set the SPARKLE_ED_PRIVATE_KEY env var to the base64-encoded
# private key (the secret) and it's piped to `--ed-key-file -`, bypassing
# the keychain. Locally the env var is unset and the tool reads the key
# from the user's keychain (where `generate_keys` stored it).
set -euo pipefail

RELEASES_DIR="${1:-./releases}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" BundleResources/Info.plist)

GEN=$(find .build/artifacts -type f -name generate_appcast -perm -u+x | head -1)
if [ -z "$GEN" ]; then
    echo "generate_appcast not found; run 'swift package resolve' first"
    exit 1
fi

if [ ! -d "$RELEASES_DIR" ]; then
    echo "Releases dir not found: $RELEASES_DIR"
    exit 1
fi

DOWNLOAD_PREFIX="https://github.com/MartinRybergLaude/jetline/releases/download/v$VERSION/"

if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    # Strip whitespace the secret may have picked up when stored
    # (GitHub Secrets preserve trailing newlines from copy-paste).
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | tr -d ' \t\n\r' | "$GEN" \
        --ed-key-file - \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        "$RELEASES_DIR"
else
    "$GEN" \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        "$RELEASES_DIR"
fi

cp "$RELEASES_DIR/appcast.xml" ./appcast.xml
echo "Appcast: ./appcast.xml"
