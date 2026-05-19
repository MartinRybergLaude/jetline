#!/usr/bin/env bash
# Push ./appcast.xml to the gh-pages branch via a temporary worktree so we
# don't disturb the working tree on main. The gh-pages branch must exist
# upstream (see README.md "Releasing" section for one-time setup).
set -euo pipefail

if [ ! -f appcast.xml ]; then
    echo "./appcast.xml not found — run scripts/generate-appcast.sh first"
    exit 1
fi

TMP=$(mktemp -d)
trap 'git worktree remove --force "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

git fetch origin gh-pages 2>/dev/null || true
if git show-ref --verify --quiet refs/remotes/origin/gh-pages; then
    git worktree add -B gh-pages "$TMP" origin/gh-pages
else
    echo "gh-pages branch missing on origin. One-time setup:"
    echo "  git checkout --orphan gh-pages && git rm -rf . && \\"
    echo "  echo 'Jetline appcast' > index.html && git add -A && \\"
    echo "  git commit -m 'Init gh-pages' && git push origin gh-pages"
    exit 1
fi

cp appcast.xml "$TMP/appcast.xml"

cd "$TMP"
git add -A
if git diff --cached --quiet; then
    echo "appcast.xml unchanged — nothing to publish"
    exit 0
fi

git -c user.name="github-actions" -c user.email="actions@github.com" \
    commit -m "Publish appcast $(date -u +%FT%TZ)"
git push origin gh-pages
echo "Published appcast.xml to gh-pages"
