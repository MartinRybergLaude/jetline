#!/usr/bin/env bash
# Bump CFBundleShortVersionString in Info.plist. CFBundleVersion is bumped
# at release time from `git rev-list --count HEAD` (see release.yml /
# release.sh), so this script only touches the human-readable version.
#
# Usage:
#   scripts/bump-version.sh             # patch bump
#   scripts/bump-version.sh patch       # 0.1.0 → 0.1.1
#   scripts/bump-version.sh minor       # 0.1.0 → 0.2.0
#   scripts/bump-version.sh major       # 0.1.0 → 1.0.0
#   scripts/bump-version.sh 1.2.3       # explicit
set -euo pipefail

PLIST=BundleResources/Info.plist
CUR=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

case "${1:-patch}" in
    major) NEW=$(awk -F. -v OFS=. '{$1++; $2=0; $3=0; print}' <<<"$CUR") ;;
    minor) NEW=$(awk -F. -v OFS=. '{$2++; $3=0; print}' <<<"$CUR") ;;
    patch) NEW=$(awk -F. -v OFS=. '{$3++; print}' <<<"$CUR") ;;
    *)     NEW="$1" ;;
esac

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
echo "$CUR → $NEW"
echo "Next: git commit -am 'Release $NEW' && git tag v$NEW && git push origin main --tags"
