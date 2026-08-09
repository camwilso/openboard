# Contributing

Thanks for looking. This is a small project with an unusual constraint: most of it
talks to a physical keypad, so some of it cannot be verified without one.

## The shape of it

```
feature branch ──► pull request ──► main ──► tag ──► release
```

Short-lived branches, squashed into `main`. Releases are cut by **tagging `main`**, never
by merging a release branch — see below for why that is not a style preference.

## Before opening a pull request

```sh
cd mac
swift build
swift run OpenBoardTests
```

The suite is a plain executable rather than XCTest. The Command Line Tools ship an
incomplete `Testing.framework` and no `xcodebuild`, so swift-testing and XCTest are both
unavailable without a full Xcode install; the harness in `Sources/OpenBoardTests/Harness.swift`
is about forty lines and prints the same pass/fail summary. It exits non-zero on failure,
which is all CI needs.

**Some tests will skip on your machine, and that is correct.** Anything asserting a fact
about *this* Mac — a paired Codex Micro, a running Claude Code — skips when the
precondition is absent rather than failing. If you see

```
  — skipped: no Codex Micro in this machine's Bluetooth report — nothing to parse
```

that is the intended behaviour, not a broken checkout.

You will also need the macOS 26 SDK to build. The app draws with Liquid Glass, and while
every call is behind `if #available(macOS 26.0, *)` — so it runs correctly on macOS 14
without it — availability gating is a runtime check, and the symbols still have to exist
at compile time.

## What CI does

Every push and pull request builds the app, runs the suite, assembles the `.app` bundle
and asserts eight things about it. It uses no secrets at all, so it runs safely on a pull
request from a fork.

The bundle assertions exist because unit tests cannot catch them: a Sparkle framework
that fails to embed, inside-out signing that breaks when a path moves, a missing
entitlement. That last one shipped as a silent failure — the app was signed with the
hardened runtime and no `com.apple.security.automation.apple-events`, so macOS denied
Apple events *without ever showing a consent dialog*, and Automation could not be granted
by anyone through any route. CI now asserts it is present.

## Testing a change that touches the pad

Build and install locally rather than downloading a CI artifact:

```sh
mac/tools/reload.sh
```

This is worth the extra step. A locally built bundle is signed with whatever identity is
in your keychain and keeps its Input Monitoring and Accessibility grants across rebuilds;
an artifact from CI is ad-hoc signed, so macOS treats every download as a brand new
application and you re-grant everything by hand to test one change.

Two harnesses exist for the things that are otherwise invisible:

| | |
|---|---|
| `mac/tools/test-onboarding.sh` | rehearses a first install — revokes permissions, points the app at a scratch state directory, so the whole no-permissions path can be walked without a second Mac |
| `mac/tools/test-update.sh` | runs a real Sparkle update against a local feed, proving download, signature verification, in-place replacement and relaunch, without publishing anything |

Both are reversible. The onboarding one costs you a few minutes re-granting permissions
afterwards, which is the point.

## Why releases are tags on `main` and nothing else

`CFBundleVersion` is the number of commits reachable from the tagged commit, and Sparkle
compares exactly that field to decide whether an update is newer. It must increase
monotonically for every build ever published.

A tag on a side branch counts a *different* set of commits — usually fewer — so it can
produce a build number lower than something already released. Sparkle then decides the
new version is older than what is installed and never offers it. The failure is silent,
permanent for that version number, and invisible except as "nobody is updating".

`mac/tools/release.sh` refuses to build from a tag that is not an ancestor of `main`, and
refuses a dirty working tree.

## Things worth knowing before changing them

Several constants and decisions here look arbitrary and are not. The reasoning lives in
comments beside the code rather than in a wiki, and most of it was paid for once already:

- **Never write the same ring configuration twice.** Re-sending it restarts the firmware
  animation, which turns a slow snake into a flicker.
- **The device acknowledges malformed requests with `ok:1` and then ignores them.** Three
  separate bugs produced clean acknowledgements and a dark pad. Verify against real
  hardware before believing a change works.
- **Keep the pad on Layer 1.** Per-key status renders only there. Writes on other layers
  succeed and do nothing.
- **The bundle id, the feed URL and the signing team are effectively permanent.** macOS
  keys TCC grants off the first two, and installed copies read the feed URL forever.

## Reporting a bug

`~/Library/Logs/OpenBoard/app.log` is where every diagnosis has started. Note that it
contains session names — which are Claude Code's own summaries of what you are working
on — along with working-directory paths. Worth a glance before pasting it anywhere.
