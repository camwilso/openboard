#!/bin/sh
# Rebuild, install and relaunch, in one step.
#
# The inner loop for working on this app. Stops the running copy before replacing the
# bundle — overwriting a live app invalidates the running process's code signature and
# it silently loses Input Monitoring mid-session.
#
# Usage: mac/tools/reload.sh [--log]     --log tails the app log afterwards

set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)

"$ROOT/tools/build-app.sh" --force --install >/dev/null
: > "$HOME/.claude/openboard/app.log" 2>/dev/null || true
open -a /Applications/OpenBoard.app
sleep 4

printf 'reloaded — '
if grep -q "device open: yes" "$HOME/.claude/openboard/app.log" 2>/dev/null; then
  printf 'pad connected\n'
else
  printf 'pad NOT connected:\n'
  grep -E "device|paint" "$HOME/.claude/openboard/app.log" 2>/dev/null | tail -3
fi

if [ "${1:-}" = "--log" ]; then
  tail -f "$HOME/.claude/openboard/app.log"
fi
