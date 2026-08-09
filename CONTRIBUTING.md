# Contributing

Thanks for looking. This is a small project with an unusual constraint: most of it talks
to a physical keypad, so some of it cannot be verified without one.

## The shape of it

```
feature branch ──► pull request ──► main ──► tag ──► release
```

Short-lived branches, squashed into `main`. Releases are cut by **tagging `main`**, never
by merging a release branch — see [Why releases are tags](#why-releases-are-tags-on-main)
for why that is not a style preference.

## Building

The app is a SwiftPM package in `mac/`, built without Xcode — SwiftUI, AppKit and IOKit
all compile against the Command Line Tools SDK.

```sh
cd mac
swift build
swift run OpenBoardTests      # a plain executable, not XCTest — see below
tools/build-app.sh --install  # assemble, sign, install to /Applications
tools/reload.sh               # rebuild, reinstall and relaunch in one step
```

You need the **macOS 26 SDK**. The app draws with Liquid Glass, and while every call is
behind `if #available(macOS 26.0, *)` — so it runs correctly on macOS 14 without it —
availability gating is a runtime check, and the symbols still have to exist at compile
time.

The one dependency is [Sparkle](https://sparkle-project.org), for updates. Xcode would
embed it; `build-app.sh` does it by hand — copy the framework in, drop the XPC services
(they are for sandboxed apps, which this is not), and sign inside out.

## Tests

A **plain executable**, not a `testTarget`. The Command Line Tools ship an incomplete
`Testing.framework` and no `xcodebuild`, so swift-testing and XCTest are both unavailable
without a full Xcode install. The harness in `Sources/OpenBoardTests/Harness.swift` is
about forty lines, prints the same pass/fail summary, and exits non-zero on failure,
which is all CI needs.

Nothing in the suite touches hardware. Everything that could — device I/O, synthetic
input, AppleScript — is either injected or lives in the app target, which the test
executable does not link. A test that types into whatever window is focused is a test you
cannot run while working.

**Some tests will skip on your machine, and that is correct.** Anything asserting a fact
about *this* Mac — a paired Codex Micro, a running Claude Code — skips when the
precondition is absent rather than failing:

```
  — skipped: no Codex Micro in this machine's Bluetooth report — nothing to parse
```

**The suite is not enough on its own.** Every bug in this project's history was invisible
to a unit test: the device acknowledges a malformed request with `ok:1` and then ignores
it, so three separate bugs produced clean acknowledgements and a dark pad. Verify against
the real pad before believing a change works.

Two harnesses exist for the things that are otherwise invisible:

| | |
|---|---|
| `mac/tools/test-onboarding.sh` | rehearses a first install — revokes permissions and points the app at a scratch state directory, so the whole no-permissions path can be walked without a second Mac |
| `mac/tools/test-update.sh` | runs a real Sparkle update against a local feed, proving download, signature verification, in-place replacement and relaunch, without publishing anything |

Both are reversible. The onboarding one costs a few minutes re-granting permissions
afterwards, which is the point.

## What CI does

Every push and pull request builds the app, runs the suite, assembles the `.app` bundle
and asserts eight things about it. It uses no secrets, so it runs safely on a pull request
from a fork.

The bundle assertions exist because unit tests cannot catch them: a Sparkle framework that
fails to embed, inside-out signing that breaks when a path moves, a missing entitlement.
That last one shipped as a silent failure — the app was signed with the hardened runtime
and no `com.apple.security.automation.apple-events`, so macOS denied Apple events *without
ever showing a consent dialog*, and Automation could not be granted by anyone through any
route.

## Testing a change that touches the pad

Build and install locally rather than downloading a CI artifact:

```sh
mac/tools/reload.sh
```

Worth the extra step. A locally built bundle is signed with whatever identity is in your
keychain and keeps its Input Monitoring and Accessibility grants across rebuilds; a CI
artifact is ad-hoc signed, so macOS treats every download as a brand new application and
you re-grant everything by hand to test one change.

## Cutting a release

```sh
git tag v0.2.0 && git push origin v0.2.0   # CI does the rest
```

`.github/workflows/release.yml` builds universal, signs with Developer ID, notarizes,
staples, appends to the appcast on the `feed` branch, and publishes the release. The same
thing runs locally as `mac/tools/release.sh`, which needs a Developer ID certificate,
notary credentials and the Sparkle private key present — it checks for all three before
building rather than failing forty seconds in.

Universal builds go one triple at a time and then `lipo`, rather than SwiftPM's
`--arch arm64 --arch x86_64`: that flag routes through XCBuild, which only ships with full
Xcode, and this project has never needed more than the Command Line Tools.

The Homebrew cask lives in [`packaging/homebrew/`](packaging/homebrew/openboard.rb); the
copy Homebrew reads is in the `camwilso/homebrew-tap` repo.

### Why releases are tags on `main`

`CFBundleVersion` is the number of commits reachable from the tagged commit, and Sparkle
compares exactly that field to decide whether an update is newer. It must increase
monotonically for every build ever published.

A tag on a side branch counts a *different* set of commits — usually fewer — so it can
produce a build number lower than something already released. Sparkle then decides the new
version is older than what is installed and never offers it. The failure is silent,
permanent for that version number, and invisible except as "nobody is updating".

`release.sh` refuses a tag that is not an ancestor of `main`, and refuses a dirty tree.

## Where help is most wanted

Support for agents other than Claude Code. Hermes and Pi are wired from their
documentation rather than from use, and each has a gap the app declares openly: Hermes has
no completion event, so a key never turns green; Pi has no documented approval event, so a
key never turns amber — which is the state the board exists for.

If you use either daily, knowing whether those signals genuinely do not exist is worth
more than a patch. See [docs/harnesses.md](docs/harnesses.md), and open an issue before
writing much — the board's model constrains what a harness has to provide.

## Things worth knowing before changing them

Several constants here look arbitrary and are not. The reasoning lives in comments beside
the code, and most of it was paid for once already:

- **Never write the same ring configuration twice.** Re-sending it restarts the firmware
  animation, which turns a slow snake into a flicker.
- **The device acknowledges malformed requests with `ok:1` and then ignores them.**
- **Keep the pad on Layer 1.** Writes on other layers succeed and do nothing.
- **The bundle id, the feed URL and the signing team are effectively permanent.** macOS
  keys permission grants off the first two, and installed copies read the feed URL forever.

## Reporting a bug

`~/Library/Logs/OpenBoard/app.log` is where every diagnosis has started. It contains
session names — Claude Code's own summaries of what you are working on — and working
directory paths. Worth a glance before pasting it anywhere.
