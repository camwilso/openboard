#!/bin/sh
# Watch a real update happen, without publishing anything.
#
# ## Why this exists
#
# The update path cannot be exercised by shipping. The first release is what people
# install, so nothing updates until the *second* — which means the first time the
# download/verify/swap/relaunch sequence runs for real is on a version that is already
# in front of users. That is a bad place to discover that the framework was embedded
# wrong or the signature does not verify.
#
# So: two throwaway builds, a feed on localhost, and an install that updates itself
# while you watch. Nothing is tagged, nothing is notarized, nothing reaches the real
# appcast.
#
# ## What it actually proves
#
# The parts that are silent when broken: that Sparkle can parse the feed, that the
# EdDSA signature verifies against the key compiled into the app, that the bundle can
# be replaced in place, and that the app comes back afterwards. It does *not* prove
# notarization or Gatekeeper — those need a Developer ID build and a real download,
# and tools/release.sh covers them.
#
# ## The version numbers
#
# Deliberately absurd: 9.9.8 and 9.9.9, far above anything real. Sparkle compares
# CFBundleVersion, so a test build has to out-rank the genuine one to be offered — and
# if one of these ever escapes onto a machine, an absurd number is the loudest possible
# clue about where it came from.
#
# Usage: mac/tools/test-update.sh [--port 8765]

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=8765

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

SERVE="${TMPDIR:-/tmp}openboard-update-test"
FEED="http://localhost:$PORT/appcast.xml"
OLD_VERSION="9.9.8"
NEW_VERSION="9.9.9"
# Above any real commit count, for the same reason the versions are absurd.
OLD_BUILD=999998
NEW_BUILD=999999

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
die() { printf '\n%s\n' "$1" >&2; exit 1; }

SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || die "sign_update not found. Run 'swift build' in mac/ first."

# Stopped on any exit, including Ctrl-C. A web server left running on a fixed port is
# the kind of thing that is discovered days later.
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

rm -rf "$SERVE"
mkdir -p "$SERVE"

# ---------------------------------------------------------------- the newer build
#
# Built first, because it is the one that gets packaged. The older one is installed
# afterwards so that it, not this, is what ends up in /Applications.

say "Building $NEW_VERSION — the update"
OB_VERSION="$NEW_VERSION" OB_BUILD="$NEW_BUILD" OB_FEED_URL="$FEED" \
  "$ROOT/tools/build-app.sh" --force >/dev/null
ditto -c -k --keepParent "$ROOT/dist/OpenBoard.app" "$SERVE/OpenBoard-$NEW_VERSION.zip"
note "$(du -h "$SERVE/OpenBoard-$NEW_VERSION.zip" | cut -f1)"

say "Signing it"
ATTRS=$("$SIGN_UPDATE" "$SERVE/OpenBoard-$NEW_VERSION.zip")
[ -n "$ATTRS" ] || die "sign_update produced nothing — is the private key in your keychain?"
note "$(printf '%s' "$ATTRS" | cut -c1-60)…"

# The same shape appcast.sh writes, so a failure here is a failure there too.
cat > "$SERVE/appcast.xml" <<FEED_XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenBoard (local test)</title>
    <link>$FEED</link>
    <description>Throwaway feed for tools/test-update.sh.</description>
    <language>en</language>
    <item>
      <title>$NEW_VERSION</title>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>Local test build</h2>
        <p>If you are reading this in a real update dialog, tools/test-update.sh
        is working. This build is not signed for distribution.</p>
      ]]></description>
      <enclosure
        url="http://localhost:$PORT/OpenBoard-$NEW_VERSION.zip"
        type="application/octet-stream"
        $ATTRS />
    </item>
  </channel>
</rss>
FEED_XML

xmllint --noout "$SERVE/appcast.xml" || die "the generated appcast is not valid XML"
note "appcast.xml written"

# ---------------------------------------------------------------- serve

say "Serving on :$PORT"
( cd "$SERVE" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
SERVER_PID=$!
sleep 1
curl -sf "$FEED" >/dev/null || die "the local server did not come up on port $PORT"
note "$FEED"

# ---------------------------------------------------------------- the older build

say "Building and installing $OLD_VERSION — the one that updates"
OB_VERSION="$OLD_VERSION" OB_BUILD="$OLD_BUILD" OB_FEED_URL="$FEED" \
  "$ROOT/tools/build-app.sh" --force --install >/dev/null
note "installed /Applications/OpenBoard.app"

open -a /Applications/OpenBoard.app
sleep 3

cat <<MSG

Now: Settings → Device → Version → Check now.

Expected, in order:

  1. "Version $NEW_VERSION is available" appears in the menu bar popover, above
     Find running sessions.
  2. Sparkle offers the update, showing the release notes from the feed.
  3. It downloads, verifies the signature, replaces the bundle, and relaunches.
  4. The Version section then reads $NEW_VERSION.

If step 3 fails, the reason is in the log rather than the dialog:

  grep -i "update\|sparkle" ~/Library/Logs/OpenBoard/app.log

The most likely failure is a signature mismatch, which means the key in
build-app.sh is not the one in your keychain — and that is worth knowing now
rather than on the first real release.

Leave this running while you test. Ctrl-C stops the server.

MSG

# Held open deliberately: the server has to outlive this script's output, and the trap
# stops it whenever the person testing is done.
wait "$SERVER_PID" 2>/dev/null || true
