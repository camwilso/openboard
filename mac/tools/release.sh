#!/bin/sh
# Cut a distributable OpenBoard release: universal build, Developer ID signature,
# notarization, stapling, and a Sparkle-signed zip ready to attach to a GitHub release.
#
# ## Why each step is here
#
# A Mac app downloaded from the internet carries a quarantine flag. Gatekeeper checks
# it against Apple's notary service, and an app that has not been through notarization
# is refused with "Apple could not verify OpenBoard is free of malware" — a dialog with
# no obvious way past it. Notarization is what turns that into a normal first launch.
#
# Stapling matters separately: without it Gatekeeper has to *reach Apple* on first
# launch to learn the app is notarized. On a machine that is offline, or behind a
# captive portal, that check fails closed. Stapling attaches the ticket to the bundle
# so the answer travels with it.
#
# The zip is made with `ditto`, not `zip`. `zip` does not preserve symlinks or extended
# attributes inside a bundle, which breaks the signature — the failure surfaces much
# later as a notarization rejection that names nothing useful.
#
# Usage: mac/tools/release.sh [--skip-notarize]
#
# Environment:
#   OB_IDENTITY         Developer ID Application identity (default: first one found)
#   OB_NOTARY_PROFILE   notarytool keychain profile (default: openboard-notary)
#   OB_SPARKLE_BIN      directory holding Sparkle's sign_update (default: search)
#
# One-time setup for notarization:
#   xcrun notarytool store-credentials openboard-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/OpenBoard.app"
PROFILE=${OB_NOTARY_PROFILE:-openboard-notary}
SKIP_NOTARIZE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
die() { printf '\n%s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
#
# Every one of these fails much later and much less clearly if left to be discovered:
# a missing identity produces an ad-hoc bundle that notarizes as "not signed with a
# Developer ID certificate", and a dirty tree produces a release whose tag does not
# describe what is in it.

say "Preflight"

# The `|| true` is load-bearing under `set -e`: git describe exits non-zero when there
# is no tag, and the message below is a great deal more useful than an unexplained exit.
VERSION=$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)
[ -n "$VERSION" ] || die "No version tag found. Tag the release first:  git tag v0.1.0"
note "version $VERSION"

# The tag must point at HEAD. Releasing from a tag that is three commits behind ships
# a binary that does not match the source anyone will read.
if [ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse "v$VERSION^{commit}")" ]; then
  die "HEAD is not at v$VERSION. Tag this commit, or check out the tag."
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  die "Working tree is dirty. Commit or stash before cutting a release."
fi

# The tag has to be on main, and this is not a style rule.
#
# CFBundleVersion is `git rev-list --count HEAD`, so it counts commits reachable from
# the tag. A tag on a side branch counts a *different* set — usually fewer — and can
# therefore produce a build number lower than one already published. Sparkle compares
# exactly that field, so it decides the new release is older than what is installed and
# never offers it.
#
# The failure is silent, permanent for that version number, and only visible as "nobody
# is updating". Nothing downstream can detect it, so it is caught here.
if ! git -C "$ROOT" merge-base --is-ancestor "v$VERSION^{commit}" origin/main 2>/dev/null \
   && ! git -C "$ROOT" merge-base --is-ancestor "v$VERSION^{commit}" main 2>/dev/null; then
  die "v$VERSION is not on main.

Release tags must be on main. The build number is the commit count reachable from the
tag, so a tag on a side branch can produce a number lower than a published release —
and Sparkle would treat the new version as older than what users already have.

Merge to main, then tag the merged commit."
fi
note "tree clean, HEAD at v$VERSION, on main"

IDENTITY=${OB_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}')}
[ -n "$IDENTITY" ] || die "No Developer ID Application certificate in the keychain.

Get one from developer.apple.com (Certificates → +  → Developer ID Application),
download it, and double-click to install. This needs a paid Developer Program
membership; nothing else in this repo does."
note "identity $IDENTITY"

if [ -z "$SKIP_NOTARIZE" ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "No notarytool credentials under the profile '$PROFILE'.

Create them once:
  xcrun notarytool store-credentials $PROFILE \\
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

The password is an app-specific password from appleid.apple.com, not your Apple
ID password."
  note "notary profile $PROFILE"
fi

# Sparkle's sign_update produces the EdDSA signature the appcast carries. It ships in
# Sparkle's binary distribution rather than the SwiftPM checkout's usual places, so
# look in both.
SIGN_UPDATE=""
for candidate in \
  "${OB_SPARKLE_BIN:-}/sign_update" \
  "$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
  "$(command -v sign_update 2>/dev/null || true)"
do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { SIGN_UPDATE="$candidate"; break; }
done
if [ -n "$SIGN_UPDATE" ]; then
  note "sign_update $SIGN_UPDATE"
else
  note "sign_update not found — the zip will be built but not signed for Sparkle"
fi

# ---------------------------------------------------------------- build

say "Building"
OB_VERSION="$VERSION" OB_IDENTITY="$IDENTITY" \
  "$ROOT/tools/build-app.sh" --release --universal --force

# A universal binary is the point of the flag; check it actually happened rather than
# trusting the flag was honoured.
ARCHS=$(lipo -archs "$APP/Contents/MacOS/OpenBoard")
note "architectures: $ARCHS"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) die "Expected a universal binary, got: $ARCHS" ;;
esac

# ---------------------------------------------------------------- package

say "Packaging"
ZIP="$DIST/OpenBoard-$VERSION.zip"
rm -f "$ZIP"
# --keepParent so the archive contains OpenBoard.app rather than its contents loose.
ditto -c -k --keepParent "$APP" "$ZIP"
note "$(basename "$ZIP") — $(du -h "$ZIP" | cut -f1)"

# ---------------------------------------------------------------- notarize

if [ -z "$SKIP_NOTARIZE" ]; then
  say "Notarizing"
  note "this usually takes 1–5 minutes"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait \
    || die "Notarization failed. For the reasons:
  xcrun notarytool log <submission-id> --keychain-profile $PROFILE"

  say "Stapling"
  # Staple the .app, not the zip — a zip cannot carry a ticket. Then rebuild the zip,
  # because the bundle on disk has changed and the archive made before stapling has
  # no ticket in it. Shipping the pre-staple zip is the classic mistake here: it
  # notarizes fine and still fails to launch offline.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  note "stapled and re-archived"

  # Gatekeeper's own verdict, which is the thing users will actually hit.
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
fi

# ---------------------------------------------------------------- sparkle signature

# Informational only, and deliberately not fatal.
#
# `appcast.sh` signs the zip itself, and that signature is the one that ships. This is
# here so a local release prints the value without waiting for the appcast step.
#
# Without a key it must not stop the build. `sign_update` reads the private key from the
# *keychain*, which exists on the maintainer's Mac and not on a CI runner — CI passes the
# key as a file to appcast.sh instead. So on the first real release this line killed the
# script after the app had been built, signed, notarized, stapled and passed Gatekeeper:
# everything expensive had already succeeded, and it failed on a courtesy.
if [ -n "$SIGN_UPDATE" ]; then
  say "Signing for Sparkle"
  if [ -n "${OB_SPARKLE_KEY_FILE:-}" ]; then
    SIGNATURE=$("$SIGN_UPDATE" "$ZIP" --ed-key-file "$OB_SPARKLE_KEY_FILE" 2>/dev/null || true)
  else
    SIGNATURE=$("$SIGN_UPDATE" "$ZIP" 2>/dev/null || true)
  fi

  if [ -n "$SIGNATURE" ]; then
    note "$SIGNATURE"
    printf '%s\n' "$SIGNATURE" > "$DIST/OpenBoard-$VERSION.sparkle"
  else
    note "no signing key here — appcast.sh will sign it"
  fi
fi

SHA=$(shasum -a 256 "$ZIP" | cut -d" " -f1)
printf '%s\n' "$SHA" > "$DIST/OpenBoard-$VERSION.sha256"

say "Done"
note "zip     $ZIP"
note "sha256  $SHA"
cat <<MSG

Next:
  gh release create v$VERSION "$ZIP" --title "v$VERSION" --notes-file <notes>
  tools/appcast.sh                      # regenerate and publish the Sparkle feed
  # then bump sha256 in the homebrew tap's Casks/openboard.rb

MSG
