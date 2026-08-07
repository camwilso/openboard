#!/bin/sh
# Build mac/dist/OpenBoard.app from the SwiftPM executable.
#
# Xcode is not installed here, so there is no xcodebuild and no asset catalog. The
# bundle is assembled by hand — the same approach the Node version used, and it works
# identically for a Swift binary.
#
# Two things carried over from that version because they were learned the hard way:
#
#  - Ad-hoc signing does NOT preserve the TCC grant across rebuilds. An ad-hoc
#    signature has no team identity, so macOS tracks the app by CDHash and a rebuild
#    is a different app as far as Input Monitoring and Accessibility are concerned.
#    Signing is still required — an unsigned bundle is not a valid TCC subject at all
#    — it just is not stable. So this is a no-op when nothing has changed.
#  - Never replace the bundle underneath a running app: it invalidates the live
#    process's signature and it loses its permissions mid-session.
#
# Usage: mac/tools/build-app.sh [--force] [--release]

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/OpenBoard.app"
CONFIG=debug
FORCE=""
INSTALL=""
INSTALL_DEST="/Applications/OpenBoard.app"

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --release) CONFIG=release; shift ;;
    --install) INSTALL=1; shift ;;
    --out) APP="$2"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v swift >/dev/null 2>&1 || {
  printf 'swift not found — install the Xcode command line tools:\n  xcode-select --install\n' >&2
  exit 1
}

# Everything that changes the built bytes.
STAMP=$(cat "$ROOT"/Sources/OpenBoard/*.swift "$ROOT"/Sources/OpenBoardKit/*.swift \
  "$ROOT"/Sources/openboard-hook/*.swift "$ROOT"/Sources/openboard-icon/*.swift "$0" \
  | shasum -a 256 | cut -d" " -f1)
STAMP="$STAMP-$CONFIG"

if [ -z "$FORCE" ] && [ -d "$APP" ]; then
  EXISTING=$(/usr/libexec/PlistBuddy -c "Print :OBSourceStamp" "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ "$EXISTING" = "$STAMP" ]; then
    printf 'unchanged — keeping the existing bundle and its permissions\n'
    printf '(--force to rebuild anyway)\n'
    exit 0
  fi
fi

printf 'building (%s)…\n' "$CONFIG"
( cd "$ROOT" && swift build -c "$CONFIG" --product OpenBoard )
# The hook helper ships inside the bundle so the path Claude Code invokes is stable —
# .build/ is a scratch directory and gets wiped by a clean.
( cd "$ROOT" && swift build -c "$CONFIG" --product openboard-hook )
BIN="$ROOT/.build/$CONFIG/OpenBoard"
HOOK_BIN="$ROOT/.build/$CONFIG/openboard-hook"
[ -x "$BIN" ] || { printf 'build produced no binary at %s\n' "$BIN" >&2; exit 1; }
[ -x "$HOOK_BIN" ] || { printf 'build produced no hook helper at %s\n' "$HOOK_BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenBoard"
cp "$HOOK_BIN" "$APP/Contents/MacOS/openboard-hook"

# The icon is the PARTY keycap's confetti glyph — the same artwork as the physical
# key, so what is in the Dock and what is under your hand are recognisably one
# product. Generated rather than checked in: there is no asset catalog (actool is an
# Xcode tool), and a vector re-renders cleanly from 16pt in a permissions list to
# 1024pt in Finder.
printf 'rendering icon…\n'
( cd "$ROOT" && swift build -c "$CONFIG" --product openboard-icon >/dev/null )
ICONSET="$ROOT/.build/OpenBoard.iconset"
"$ROOT/.build/$CONFIG/openboard-icon" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OpenBoard.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>OpenBoard</string>
  <key>CFBundleDisplayName</key>        <string>OpenBoard</string>
  <key>CFBundleExecutable</key>         <string>OpenBoard</string>
  <key>CFBundleIdentifier</key>         <string>com.openboard.app</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>CFBundleVersion</key>            <string>1</string>
  <key>LSMinimumSystemVersion</key>     <string>14.0</string>

  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>                <true/>
  <!-- Reading the pad's battery from the standard GATT Battery Service. Without this
       string CoreBluetooth refuses to initialise, and the app is denied rather than
       prompted. -->
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>OpenBoard reads the Codex Micro's battery level.</string>
  <key>CFBundleIconFile</key>           <string>OpenBoard</string>

  <key>OBSourceStamp</key>              <string>$STAMP</string>
</dict>
</plist>
PLIST

# Sign with a real identity when one exists, ad-hoc otherwise.
#
# This is what stops every rebuild costing an Input Monitoring grant. An ad-hoc
# signature has no team identity, so macOS tracks the app by CDHash and any rebuild
# is a different app as far as TCC is concerned. A certificate — even a self-signed
# one in the login keychain — gives the signature a stable designated requirement,
# so the grant survives.
#
# Create one with tools/make-signing-cert.sh. Nothing about it requires an Apple
# Developer account; that is only needed to notarize for *other people's* machines.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "OpenBoard Local Signing" | head -1 | awk '{print $2}')

if [ -n "$IDENTITY" ]; then
  printf 'signing with OpenBoard Local Signing…\n'
  codesign --force --sign "$IDENTITY" --identifier com.openboard.app \
    --options runtime "$APP" 2>&1 | grep -v "replacing existing" || true
else
  printf 'signing ad-hoc (no identity found — grants will not survive rebuilds)…\n'
  codesign --force --sign - --identifier com.openboard.app "$APP" 2>&1 | grep -v "replacing existing" || true
fi

if [ -n "$INSTALL" ]; then
  # Replace wholesale rather than merge: a half-old bundle is a signature that
  # matches nothing. Anything running from the destination has to stop first, since
  # overwriting a live app invalidates the running process's signature and it loses
  # its permissions mid-session.
  #
  # Matched on the *destination*, not on the name. It used to kill any process whose
  # path contained OpenBoard.app, so a build installing somewhere else — a scratch
  # clone, a second checkout — quietly stopped the copy in /Applications and left the
  # board dark with nothing to explain it.
  pkill -f "$INSTALL_DEST/Contents/MacOS/OpenBoard" 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALL_DEST"
  cp -R "$APP" "$INSTALL_DEST"
  printf 'installed %s\n' "$INSTALL_DEST"
fi

printf 'built %s\n' "$APP"
printf 'hook helper: %s\n' "$APP/Contents/MacOS/openboard-hook"
if [ -n "$IDENTITY" ]; then
  printf 'signed with a stable identity — existing permission grants carry over.\n'
else
  printf 'NOTE: ad-hoc signed, so macOS sees a new app — Input Monitoring and\n'
  printf '      Accessibility must be re-granted before the pad will respond.\n'
fi
