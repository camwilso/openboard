#!/bin/sh
# Add this release to the Sparkle feed served at updates.openboardapp.com.
#
# ## Why this is hand-rolled rather than `generate_appcast`
#
# Sparkle ships `generate_appcast`, which scans a directory of zips and writes the
# whole feed. It applies one `--download-url-prefix` to every file it finds, and
# GitHub Releases puts each asset under its own tag:
#
#   https://github.com/camwilso/openboard/releases/download/v0.2.0/OpenBoard-0.2.0.zip
#   https://github.com/camwilso/openboard/releases/download/v0.3.0/OpenBoard-0.3.0.zip
#
# One prefix cannot produce both. The options are to post-process its output or to
# append one `<item>` per release, and appending is the smaller, more obvious thing —
# an appcast is RSS, and the only part that needs a tool is the signature.
#
# ## Where the feed lives
#
# An orphan `feed` branch, checked out as a git worktree. Cloudflare Workers Builds
# watches that branch and deploys it to updates.openboardapp.com, so pushing the branch
# is the whole deploy — no API token, no upload step, nothing for CI to authenticate
# against beyond the push it already does.
#
# The branch carries a `wrangler.jsonc` declaring `public/` as the assets directory,
# which is why the feed is written to public/appcast.xml rather than the branch root:
# only what is inside public/ is served, so the config and the README are not.
#
# Orphan because the feed shares no history with the source, and a branch that did would
# publish the entire repository. A separate branch also keeps release churn out of
# main's history: the appcast changes on every release and is not something anyone reads.
#
# Not `docs/` on the default branch, which is the other obvious spot: `docs/` is already
# gitignored here for working notes, and putting a published file inside an ignored
# directory of private notes is one `git add docs/` away from leaking them.
#
# Usage: mac/tools/appcast.sh [--notes <file>]

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
WORKTREE="$REPO/.feed"
# public/ rather than the branch root: the branch is deployed by Cloudflare Workers
# Builds, whose wrangler.jsonc points `assets.directory` here. Anything outside public/
# — the config, the README — is deliberately not served.
FEED="$WORKTREE/public/appcast.xml"
DIST="$ROOT/dist"
NOTES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf '%s\n' "$1" >&2; exit 1; }

VERSION=$(git -C "$REPO" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//')
[ -n "$VERSION" ] || die "No version tag found."
BUILD=$(git -C "$REPO" rev-list --count HEAD)
ZIP="$DIST/OpenBoard-$VERSION.zip"
[ -f "$ZIP" ] || die "No zip at $ZIP — run tools/release.sh first."

SIGN_UPDATE=""
for candidate in \
  "${OB_SPARKLE_BIN:-}/sign_update" \
  "$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
  "$(command -v sign_update 2>/dev/null || true)"
do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { SIGN_UPDATE="$candidate"; break; }
done
[ -n "$SIGN_UPDATE" ] || die "sign_update not found. Run 'swift build' in mac/ so SwiftPM fetches Sparkle's tools."

# sign_update prints the two attributes ready to paste:
#   sparkle:edSignature="…" length="…"
# It reads the private key from the keychain by default; --ed-key-file for CI, where
# there is no keychain to read.
if [ -n "${OB_SPARKLE_KEY_FILE:-}" ]; then
  ATTRS=$("$SIGN_UPDATE" "$ZIP" --ed-key-file "$OB_SPARKLE_KEY_FILE")
else
  ATTRS=$("$SIGN_UPDATE" "$ZIP")
fi
[ -n "$ATTRS" ] || die "sign_update produced nothing — is the private key in your keychain?"

# RFC 822, which is what RSS wants. The tag date rather than now: re-running this must
# not change the feed for a release that already went out.
PUBDATE=$(git -C "$REPO" log -1 --format=%cD "v$VERSION")

if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
  # CDATA so the notes can contain HTML without escaping, which is the point of
  # release notes in an appcast — Sparkle renders them in the update dialog.
  DESCRIPTION="      <description><![CDATA[
$(cat "$NOTES")
      ]]></description>"
else
  DESCRIPTION="      <sparkle:releaseNotesLink>https://github.com/camwilso/openboard/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
fi

ITEM=$(cat <<ITEM
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
$DESCRIPTION
      <enclosure
        url="https://github.com/camwilso/openboard/releases/download/v$VERSION/OpenBoard-$VERSION.zip"
        type="application/octet-stream"
        $ATTRS />
    </item>
ITEM
)

# Check the feed branch out beside the working tree, creating it the first time.
if [ ! -d "$WORKTREE" ]; then
  if git -C "$REPO" show-ref --verify --quiet refs/heads/feed; then
    git -C "$REPO" worktree add "$WORKTREE" feed >/dev/null
  elif git -C "$REPO" ls-remote --exit-code --heads origin feed >/dev/null 2>&1; then
    git -C "$REPO" fetch origin feed:feed >/dev/null 2>&1
    git -C "$REPO" worktree add "$WORKTREE" feed >/dev/null
  else
    printf 'creating the feed branch\n'
    git -C "$REPO" worktree add --detach "$WORKTREE" >/dev/null
    git -C "$WORKTREE" checkout --orphan feed >/dev/null 2>&1
    git -C "$WORKTREE" rm -rf . >/dev/null 2>&1 || true
  fi
fi

mkdir -p "$(dirname "$FEED")"
if [ ! -f "$FEED" ]; then
  cat > "$FEED" <<HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenBoard</title>
    <link>https://updates.openboardapp.com/appcast.xml</link>
    <description>Updates to OpenBoard.</description>
    <language>en</language>
  </channel>
</rss>
HEADER
fi

# Already published? Re-running must be a no-op, not a duplicate entry — Sparkle shows
# whichever it parses first and the feed silently grows.
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$FEED"; then
  printf '%s is already in the feed — nothing to do.\n' "$VERSION"
  exit 0
fi

# Newest first: insert directly after </language>, which closes the channel metadata
# and precedes every item.
#
# The item is passed through a file rather than `awk -v`. A -v assignment cannot carry
# literal newlines — awk parses the value as a string constant and fails with
# "newline in string" — so a multi-line block silently does not get inserted while the
# script reports success.
TMP=$(mktemp)
ITEMFILE=$(mktemp)
trap 'rm -f "$TMP" "$ITEMFILE"' EXIT
printf '%s\n' "$ITEM" > "$ITEMFILE"
awk -v f="$ITEMFILE" '
  { print }
  /<\/language>/ && !inserted {
    while ((getline line < f) > 0) print line
    close(f)
    inserted = 1
  }
' "$FEED" > "$TMP"

grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$TMP" \
  || die "Failed to insert the item into the feed — is <\/language> still in the header?"
mv "$TMP" "$FEED"

printf 'added %s (build %s) to %s\n' "$VERSION" "$BUILD" "$FEED"

# Committed here rather than left for the caller: the worktree is an implementation
# detail of this script, and leaving a dirty orphan branch lying around is a trap for
# whoever runs it next.
git -C "$WORKTREE" add public/appcast.xml
if git -C "$WORKTREE" diff --staged --quiet; then
  printf 'no change to commit\n'
else
  git -C "$WORKTREE" commit -q -m "appcast: $VERSION"
  printf 'committed to feed\n'
fi

printf '\nThe feed is only live once it is pushed:\n'
printf '  git push origin feed\n'
