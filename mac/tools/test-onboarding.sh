#!/bin/sh
# Rehearse a first install, on the machine you already use.
#
# ## What this is for
#
# Everything a new user meets is state you do not have: no config, no calibration, no
# hooks, and — the part that matters most — no permissions. That last one is why
# onboarding bugs survive so long. The developer granted Input Monitoring months ago,
# so every path that depends on *not* having it is code nobody has run since.
#
# macOS makes this testable without a second Mac. `tccutil reset` genuinely clears the
# grants, and the app already honours OPENBOARD_HOME and CLAUDE_CONFIG_DIR, so its
# state directory and the settings.json it edits can both be pointed somewhere
# disposable.
#
# ## What it deliberately does not do
#
# It does not touch your real ~/.claude/settings.json. Wiring hooks is part of
# onboarding, and a test that rewrites the file every session in this terminal is a
# test that costs more than it finds.
#
# The app is launched through `open`, not by running the binary. That is not a detail:
# TCC attributes a permission request to the *responsible* process, and a binary
# started from a shell is attributed to the terminal. Prompts would say Terminal wants
# to control your Mac, the grants would land on the wrong application, and the
# rehearsal would be of something that never happens to a user.
#
# Usage: mac/tools/test-onboarding.sh [--keep] [--no-reset]
#   --keep      leave the scratch directories behind for inspection
#   --no-reset  skip tccutil, when you only want the clean-state half

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="/Applications/OpenBoard.app"
BUNDLE_ID="com.openboardapp.mac"
SCRATCH="${TMPDIR:-/tmp}openboard-onboarding-$$"
KEEP=""
RESET=1

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --no-reset) RESET=""; shift ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

[ -d "$APP" ] || {
  printf 'No app at %s — run mac/tools/build-app.sh --install first.\n' "$APP" >&2
  exit 1
}

# ---------------------------------------------------------------- consent
#
# Resetting TCC is not reversible and costs *you* the grants, not a test user. Asked
# out loud rather than buried behind a flag, because the person running this is the
# person who then has to click through four System Settings panes to get back.

if [ -n "$RESET" ]; then
  cat <<MSG

This revokes OpenBoard's permissions on THIS Mac:

  Input Monitoring, Accessibility, Bluetooth, and Automation

You will have to grant them again by hand afterwards — that is the point of the
exercise, but it is a real cost and takes a few minutes.

MSG
  printf 'Reset them and rehearse onboarding? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf 'Nothing changed.\n'; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- clean state

say "Clean state"
mkdir -p "$SCRATCH/support" "$SCRATCH/claude"
# An empty settings.json rather than no file: "the file is missing" and "the file has
# no hooks" are different paths through HookInstall, and the second is what a user with
# an existing Claude Code install actually has.
printf '{}\n' > "$SCRATCH/claude/settings.json"
note "state    $SCRATCH/support"
note "settings $SCRATCH/claude/settings.json"

# ---------------------------------------------------------------- reset TCC

if [ -n "$RESET" ]; then
  say "Revoking permissions"
  # Named individually rather than `All`: `tccutil reset All <id>` also clears things
  # this app never asked for, and the output is then a list of services that were never
  # relevant. These are exactly the four the Device pane reports on.
  for service in ListenEvent Accessibility Bluetooth AppleEvents; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
      note "$service reset"
    else
      note "$service — nothing to reset"
    fi
  done
fi

# ---------------------------------------------------------------- launch

say "Launching"
# Stop the copy that is running against your real state, so the one that starts is the
# one being tested. Matched on the destination path rather than the name.
pkill -f "$APP/Contents/MacOS/OpenBoard" 2>/dev/null || true
sleep 1

open -a "$APP" \
  --env "OPENBOARD_HOME=$SCRATCH/support" \
  --env "CLAUDE_CONFIG_DIR=$SCRATCH/claude"
note "opened with a scratch state directory"

cat <<'MSG'

Walk it as a new user would, in this order — each step is one someone hits before
anything on the pad lights:

  1. The menu bar item. Does the popover explain what is wrong, or is it empty?
  2. Settings → Device. Every permission should read denied or not asked, and each
     row's Open button should land on the right System Settings pane.
  3. Grant Input Monitoring, then restart the app. It should now find the pad.
  4. Key order should say "Not checked" — it is a fresh state directory.
  5. Grant permissions, for Automation. System Events should end up granted without
     you visiting System Settings at all.
  6. Version should say the build cannot update itself if this was built locally,
     or check the real feed if it was signed with the Developer ID.

Then quit OpenBoard and re-run it normally to go back to your own state.

MSG

if [ -z "$KEEP" ]; then
  printf 'Press return to clean up the scratch directories (or Ctrl-C to keep them). '
  read -r _
  rm -rf "$SCRATCH"
  printf 'Removed %s\n' "$SCRATCH"
else
  printf 'Left in place: %s\n' "$SCRATCH"
fi
