#!/usr/bin/env bash
# Build `jetlined` for Linux in Docker.
#
#   scripts/linux/build-daemon.sh [x86_64|aarch64]    (default: this Mac's arch)
#
# Produces dist/jetlined-linux-<arch>: a release build with the Swift
# runtime and SQLite linked in statically. At runtime it needs only glibc
# ≥ 2.35 and libstdc++ (Ubuntu 22.04+, Debian 12+). Building for the other
# architecture uses
# Docker's emulation (Rosetta under OrbStack / Docker Desktop), which is
# slower but works.
set -euo pipefail

cd "$(dirname "$0")/../.."
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
    arm64|aarch64) ARCH=aarch64; PLATFORM=linux/arm64 ;;
    x86_64|amd64)  ARCH=x86_64;  PLATFORM=linux/amd64 ;;
    *) echo "unknown architecture: $ARCH" >&2; exit 1 ;;
esac

IMAGE="jetline-linux-build:$ARCH"
docker build --quiet --platform "$PLATFORM" -t "$IMAGE" -f scripts/linux/Dockerfile.build scripts/linux >/dev/null

mkdir -p dist
LOG=$(mktemp -t jetlined-build)
echo "Building jetlined for linux/$ARCH (log: $LOG)…"
# Build in a volume, not the checkout's .build (that one is macOS's).
if ! docker run --rm --platform "$PLATFORM" \
    -v "$PWD":/src \
    -v "jetline-daemon-build-$ARCH":/build \
    -w /src "$IMAGE" \
    bash -c "swift build -c release --product jetlined --static-swift-stdlib --build-system native --scratch-path /build \
             && cp \$(swift build -c release --build-system native --scratch-path /build --show-bin-path)/jetlined /src/dist/jetlined-linux-$ARCH \
             && strip /src/dist/jetlined-linux-$ARCH" >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -20 >&2
    echo "Build failed; full log in $LOG" >&2
    exit 1
fi

echo "Built dist/jetlined-linux-$ARCH ($(du -h "dist/jetlined-linux-$ARCH" | cut -f1))"
