#!/usr/bin/env bash
# Install `jetlined` on a Linux host you can ssh into.
#
#   scripts/linux/deploy-daemon.sh <ssh-host> [remote-path]
#
# <ssh-host> is anything `ssh` accepts (an alias from ~/.ssh/config,
# user@host). The binary goes to ~/.jetline/bin/jetlined unless
# remote-path says otherwise — the path the Jetline app's Remote settings
# expect by default. Extra ssh/scp options can go in JETLINE_SSH_OPTS
# (e.g. "-p 2222 -i ~/.ssh/other_key").
set -euo pipefail

cd "$(dirname "$0")/../.."
HOST="${1:?usage: deploy-daemon.sh <ssh-host> [remote-path]}"
REMOTE_PATH="${2:-.jetline/bin/jetlined}"
# (macOS bash is 3.2: empty arrays need the ${a[@]+...} dance under set -u.)
read -r -a OPTS <<< "${JETLINE_SSH_OPTS:-}"
SCP_OPTS=()
for opt in ${OPTS[@]+"${OPTS[@]}"}; do
    [ "$opt" = "-p" ] && SCP_OPTS+=("-P") || SCP_OPTS+=("$opt")
done
ssh() { command ssh ${OPTS[@]+"${OPTS[@]}"} "$@"; }
scp() { command scp ${SCP_OPTS[@]+"${SCP_OPTS[@]}"} "$@"; }

echo "Checking ${HOST}…"
REMOTE_ARCH=$(ssh "$HOST" uname -m)
REMOTE_OS=$(ssh "$HOST" uname -s)
if [ "$REMOTE_OS" != "Linux" ]; then
    echo "$HOST runs $REMOTE_OS. On a Mac host, point Jetline at the app's own daemon instead:" >&2
    echo "  /Applications/Jetline.app/Contents/MacOS/jetline daemon attach" >&2
    exit 1
fi

scripts/linux/build-daemon.sh "$REMOTE_ARCH"
case "$REMOTE_ARCH" in arm64|aarch64) ARCH=aarch64 ;; *) ARCH=x86_64 ;; esac

echo "Installing to $HOST:~/${REMOTE_PATH}…"
ssh "$HOST" "mkdir -p \"\$(dirname ~/$REMOTE_PATH)\""
scp -q "dist/jetlined-linux-$ARCH" "$HOST:$REMOTE_PATH.new"
ssh "$HOST" "chmod +x ~/$REMOTE_PATH.new && mv ~/$REMOTE_PATH.new ~/$REMOTE_PATH && ~/$REMOTE_PATH version"

if ssh "$HOST" "~/$REMOTE_PATH status" >/dev/null 2>&1; then
    echo
    echo "An engine is already running on $HOST; it keeps the old version until it"
    echo "restarts. \`ssh $HOST ~/$REMOTE_PATH stop\` restarts it on the next connection"
    echo "(and ends the agents and terminals it's running)."
fi

MISSING=$(ssh "$HOST" 'for t in git gh claude codex; do command -v $t >/dev/null 2>&1 || printf "%s " $t; done' || true)
if [ -n "$MISSING" ]; then
    echo
    echo "Not on $HOST's PATH: ${MISSING}— install what you use (and log in) on the host."
fi

echo
echo "Done. In Jetline: Settings → Remote → A remote machine → SSH host: $HOST"
