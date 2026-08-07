#!/bin/sh
# Set up OpenBoard on a Mac that has never had it.
#
# One command, because the install is four steps and three of them are only
# discoverable by reading. It creates the local signing identity, builds, installs to
# /Applications and opens the app — then tells you the two things it cannot do for you.
#
# Safe to re-run. Every step checks before acting: an existing certificate is kept, an
# unchanged build is not rebuilt, and a running app is stopped before its bundle is
# replaced rather than after.
#
# Usage: mac/tools/bootstrap.sh

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

# ---------------------------------------------------------------- prerequisites

say "Checking what is here"

if ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'MSG'
swift not found.

OpenBoard builds with the Xcode Command Line Tools — not the full Xcode, which it
deliberately does not require. Install them and run this again:

  xcode-select --install
MSG
  exit 1
fi
note "swift $(swift --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//')"

MACOS=$(sw_vers -productVersion)
MAJOR=${MACOS%%.*}
if [ "$MAJOR" -lt 14 ]; then
  printf 'macOS %s is older than the 14.0 this needs.\n' "$MACOS" >&2
  exit 1
fi
note "macOS $MACOS"

# ---------------------------------------------------------------- signing identity
#
# Before the build, and this ordering is the whole reason the script exists. macOS
# identifies an application by its code signature when granting Input Monitoring and
# Accessibility. An ad-hoc signature has no stable identity, so every rebuild is a new
# application to the system and every permission has to be granted again by hand — and
# the symptom is not an error, it is an app that looks fine and silently cannot open
# the pad.

say "Local signing identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenBoard Local Signing"; then
  note "already in your keychain"
else
  note "creating one — this is self-signed and needs no Apple account"
  "$ROOT/tools/make-signing-cert.sh"
fi

# ---------------------------------------------------------------- build and install

say "Building"
"$ROOT/tools/build-app.sh" --release --install

say "Opening"
open /Applications/OpenBoard.app

# ---------------------------------------------------------------- what is left
#
# Named explicitly rather than left to be discovered. Each of these is per-machine and
# cannot be copied from another Mac, which is the part people expect to be able to skip.

cat <<'MSG'

Two things this cannot do for you, both in Settings → Device:

  1. Grant permissions. Input Monitoring and Accessibility are per-application and
     only take effect after OpenBoard restarts. Bluetooth is for the battery readout,
     and Automation → Terminal is what lets a key jump to a chat.

  2. Wire the hooks. Settings → the harness in the sidebar → Events → Repair. This
     edits ~/.claude/settings.json, keeping every unrelated setting and any other
     tool's hooks, and backs the file up beside itself first. Without them the app
     runs, the pad connects, and nothing ever lights.

And pair the Codex Micro with this Mac, over Bluetooth or USB, with the pad on
Layer 1 — status renders only there.

MSG
