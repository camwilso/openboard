# OpenBoard

Drive the six Agent-key LEDs on a Work Louder **Codex Micro** from your **Claude Code** sessions, so
you can see at a glance which session is working, which finished, and which is blocked waiting on you.

By **Cam Wilson** — [cam-wilson.com](https://cam-wilson.com) · MIT licensed.

> [!NOTE]
> **Keep the pad on Layer 1.** Per-key status renders only there — writes succeed on other layers
> and simply do not appear. Layer 1 is also not editable, and flashing other firmware does not
> help: this is a Codex-integrated pad and the LEDs are its feature, not ours.

> [!IMPORTANT]
> Unofficial and experimental. This rides a private Codex Micro HID command that can change with any
> ChatGPT, Work Louder Input, or firmware update. Not affiliated with or endorsed by OpenAI,
> Anthropic, or Work Louder.

## Why

Running several Claude Code sessions at once, the expensive question is *which one is blocked on a
permission prompt* — cheap to answer, costly to miss. That's one bit of ambient status per session,
which is a bad fit for a screen and a good fit for six LEDs under your hand.

## How slots are assigned

A session claims a key when it starts and **keeps it**. Slots are reclaimed only once six newer
sessions have cycled through, and eviction skips any key currently signalling *awaiting input*.

This is deliberately unlike Codex's "most recent chats" mode, where a key number is your rank in a
live recency sort — so typing in one chat can repaint four other keys. Status you can't trust is
worse than no status.

No configuration, no project list, no per-user setup: rotation works out of the box.

## States

Color *hues* follow OpenAI's own Codex Micro Agent Key legend, so a key means
the same thing whether Codex or Claude painted it — but saturated and darkened, because
OpenAI's pastels are drawn for a light web page and wash out on an emissive LED.

| State | Color | OpenAI's label | Meaning |
|---|---|---|---|
| idle | `#2E4A6B` dim | idle | session started, nothing running |
| working | `#0C47E9` breath | thinking | turn in progress |
| **awaiting** | **`#FF6A00` breath** | **needs input** | **blocked on a permission prompt — go here.** Clears when the prompt is answered, either way |
| stalled | `#FF6A00` shallow | — | idle prompt |
| done | `#09B821` | complete | turn finished — **holds until you go back and send something**, so work that finished while you were elsewhere is still there when you look |
| error | `#D41145` breath | error | turn failed |

## The outer ring

The ring summarises the whole board in one glance — it is visible from across the room,
where six small keys are not. So it does not duplicate them: the most urgent state
anywhere wins.

The ring is **dark by default** and fires only on a transition. A ring that is always lit
is furniture; one that is dark until something happens is a notification.

| Event | Ring |
|---|---|
| a chat finishes | green **snake** — one slow lap, 4.2s |
| a chat stops to ask something | orange **snake** — one lap, 3.2s |
| a turn fails | red **heartbeat**, 3.0s |

Each step is written **once** and left to run. Re-sending the same config restarts the
firmware animation, which turned a slow snake into a flicker, and the reasserter would
otherwise darken the ring partway through — so a show takes a short expiring lock that
`sync` respects.

Errors get a different *shape*, not just a different color: peripheral vision reads
motion before hue, so a failure must not be mistakable for a completion. `snake` is used
only here — spatial effects render dark on a single Agent key.

Laps fire on the state actually changing, never on a repaint — `Notification` follows
`PermissionRequest` with the same state, and the reasserter repaints every 10s.

`ambient.mode` also accepts `aggregate` (continuously summarise the board), `fixed`, and
`off`. Individual laps: `completionLap`, `questionLap`, `errorPulse`.

## Requirements

- macOS 14 or later
- Work Louder Codex Micro paired with this Mac, over Bluetooth or USB
- Claude Code
- Xcode Command Line Tools, to build it — `xcode-select --install`

No runtime dependencies and no network requests. The app talks to the pad through
IOKit directly, so unlike the Node version it does not need ChatGPT.app or Work Louder
Input installed to borrow a native HID binding from.

**Why it stays running.** The protocol offers no lighting readback and Codex reclaims
the LEDs on its own schedule, so a one-shot write is correct only at the instant it
lands. The app re-asserts the board on an interval — every ~10s while the pad is
present, every ~2s while it is missing, because over Bluetooth LE disconnecting is
normal rather than exceptional. An early version of this file promised "no daemon";
that promise could not survive the protocol.

## Which sessions get a light

Only sessions that run as a **local process on this Mac** — hooks execute in that process and only a
local process can reach the hardware.

| Surface | Gets a light |
|---|---|
| Terminal | yes |
| VS Code integrated terminal | yes |
| VS Code, extension-hosted | yes |
| Subagents | no — by design, six keys is a scarce budget |
| Embedded Agent SDK consumers | no — other tools spawn `claude` and would exhaust the keys |
| claude.ai/code, cloud routines, SSH, remote spaces | unreachable — no local process |

Eligibility is a fail-closed allowlist: an unrecognised surface gets no light rather than quietly
stealing one.

## Install

There is no download. You build it, which is also why there is no Gatekeeper prompt to
click through: an app you compiled yourself was never quarantined.

```sh
git clone https://github.com/camwilso/openboard
cd openboard
mac/tools/bootstrap.sh
```

That does the whole build: it creates the local signing identity, compiles, installs to
`/Applications` and opens the app. It is safe to re-run. The steps below are what it
does and the two it cannot do for you.

```sh
mac/tools/make-signing-cert.sh      # what bootstrap runs first — see step 1
mac/tools/build-app.sh --install
```

1. **Create the local signing identity** with `mac/tools/make-signing-cert.sh`. Do this
   *before* the first build. macOS grants Input Monitoring and Accessibility to an
   application identified by its code signature, and an ad-hoc signature has no stable
   identity — so every rebuild is a brand new app to the system, and every permission
   has to be granted again by hand. The symptom is nasty: the app looks fine and
   silently cannot open the pad. A self-signed certificate fixes it. Nothing here
   involves an Apple Developer account.
2. **Build and install the app**: `mac/tools/build-app.sh --install`, which puts
   `OpenBoard.app` in `/Applications`. Open it — it lives in the menu bar with no Dock
   icon.
3. **Grant permissions**, in Settings → Device. Each is per-application and only takes
   effect after the app restarts:
   - **Input Monitoring** — reading the pad, so every light and every key
   - **Accessibility** — typing snippets, sending ⏎ and ⎋, scrolling
   - **Automation** → Terminal for jumping to a chat, QuickTime Player for fun mode
4. **Check the key order** in Settings → Device — optional, and worth ten seconds. The
   board runs on the layout every pad so far reports (slot 1 top-left, reading order),
   so it lights immediately. The check paints six colors and asks one question: are they
   in that order? If your pad disagrees, the same screen lets you map it by hand.
5. **Wire the hooks**, in Settings → Device → Hooks. It audits `~/.claude/settings.json`
   and offers to repair it, preserving every unrelated setting and any other tool's
   hooks on the same events. It backs the file up first.
6. **Keep the pad on Layer 1.** Per-key status renders only there; Layer 2 allows custom
   keycodes but never shows status.

Hooks load at session start, so open a new session to see it work. Sessions already
running are picked up too — the app walks the process table at launch rather than
waiting for each one to do something.

Turn on **Open OpenBoard at login** in Settings → Device. A board you have to remember
to launch is not an ambient board.

## Where it keeps things

| | |
|---|---|
| `~/Library/Application Support/OpenBoard/` | `config.json`, `calibration.json`, `registry.json`, and the hook socket |
| `~/Library/Logs/OpenBoard/app.log` | what the app saw and did |

`config.json` is plain JSON and safe to hand-edit — it is merged field by field over the
defaults, so a partial file is valid, and it holds a few things the settings window does
not expose. Settings → Device → Your settings will reveal either in Finder.

**What the log contains.** Session names — which are Claude Code's own summaries of what
you are working on — along with working-directory paths, and which key is lit. It never
leaves the machine, but it is worth knowing before you paste it into a bug report. Delete
it whenever; the app makes a new one.

## Moving to another Mac

Everything the app *is* travels in the repo; nothing it *knows* does. Clone, run
`mac/tools/bootstrap.sh`, and expect to redo four things by hand.

**Do not copy `OpenBoard.app` across.** It is signed with a certificate that exists only
in the keychain of the machine that built it, so on any other Mac the signature verifies
against nothing — and a bundle that arrives over AirDrop or a USB stick is quarantined
besides. Building takes about a minute and avoids both.

| | Travels | Why not |
|---|---|---|
| The app, the tools, the docs | ✅ in the repo | |
| Session colours, key bindings, keycaps | ⚠️ copy the file | see below |
| Which physical key is slot 1 | ⚠️ copy the file | or just re-check it, ten seconds |
| Permissions | ❌ | granted per application **per machine**, by macOS |
| Hooks in `~/.claude/settings.json` | ❌ | the command is an absolute path into that Mac's `/Applications` |
| The local signing identity | ❌ | a private key, and it should stay in one keychain |
| The pad itself | ❌ | pair it with the new Mac, and keep it on Layer 1 |
| Fun mode's video | ❌ | 90MB and not ours to redistribute, so it is gitignored |

Settings, when you want them — both files are plain JSON and safe to copy while the app
is closed:

```sh
~/Library/Application\ Support/OpenBoard/config.json        # colours, bindings, caps
~/Library/Application\ Support/OpenBoard/calibration.json   # key order, if you recorded one
```

Leave `registry.json` behind. It is the board's memory of *that* Mac's sessions — process
ids and ttys that mean nothing here, and it rebuilds itself the moment a session reports.

## Uninstall

Nothing is installed outside your home directory except the app itself.

1. Quit OpenBoard from the menu bar, and turn off **Open at login** first if it is on.
2. Remove the hook entries from `~/.claude/settings.json` — the eight `openboard-hook`
   commands under `hooks`. Every install writes a `settings.backup-<timestamp>.json`
   beside it, so the one from before you started is a clean restore.
3. `rm -rf /Applications/OpenBoard.app`
4. `rm -rf ~/Library/Application\ Support/OpenBoard ~/Library/Logs/OpenBoard`
5. Optionally `security delete-identity -c "OpenBoard Local Signing"` to remove the local
   signing certificate.

Do not skip step 2. The helper exits quietly when the app is merely *not running*, which
is normal and costs nothing — but once the bundle is deleted the hooks point at a binary
that is not there, and every session will try to run it on every event.

## Jumping to a session

**Press the Agent Key.** The device broadcasts every key event on the vendor RPC
channel as a notification (`{"m":"v.oai.hid","p":{"k":"AG00","act":1}}`), so presses
are intercepted without remapping anything — Codex's locked keycodes stay intact and
the pad stays on Layer 1 where the lights work. The app does the intercepting.

The seven action keys are configurable via `config.actionKeys`; `ACT06` repaints the
board by default.

Clicking a session in the menu-bar popover does the same thing.

| Surface | How | Precision |
|---|---|---|
| Terminal | matches the session's `tty` against Terminal's per-tab `tty` | exact tab |
| VS Code | `code -r <cwd>` on the session's workspace folder | right window, not the specific panel |

**Press the Agent key itself.** They emit vendor keycodes rather than keystrokes, so nothing else
on the system sees them — no hotkey daemon, no global shortcut, no conflict with anything you have
bound. Early versions routed this through a second keyboard and `skhd` on the assumption the presses
were unreadable; they are not.

The dial does the rest: press it for the menu-bar popover, hold it for Settings. Every other key on
the pad is yours to bind in Settings → Board.

## Coexisting with Codex

The ChatGPT app repaints these LEDs on its own schedule and does not participate in the HID write
lock. If you use both, either set Codex to **Custom assignments** and cede it a subset of keys, or
accept periodic repaint. This tool shares upstream's lock path so the two never interleave writes
mid-message.

## Fun mode

`ACT12` plays the video full-screen and drives the pad in time with it. It deliberately
overrides live agent status for its duration; `sync` restores the real board afterwards.

The beat grid and the dynamics are derived, not guessed. `the-final-countdown/analyse-audio.cjs` reads a
mono WAV with no dependencies: RMS envelope, positive first difference as an onset signal,
tempo by autocorrelating that, then the grid phase landing on the most onset energy. It also
emits per beat:

| Field | What | Why |
|---|---|---|
| `i` | overall intensity 0–1 | how big the moment is |
| `b` | **bass** 30–250Hz | the pulse you feel |
| `h` | **highs** 2.6–7kHz | cymbals, hats, synth attack |
| `v` | **centre-channel lead** 600–2.6kHz | tracks the singing — see below |
| `a` | accent flag | thresholded against *other beats*, not all audio frames; against frames it flagged 46% of beats |

Bands are summed from FFT bins, not filtered. An earlier version cascaded one-pole filters,
which roll off at 6dB/octave — every "band" leaked the kick and the cymbals, so all of them
just tracked loudness and the vocal signal had no verse/chorus shape whatsoever.

### Voice detection, honestly

`v` is **centre-channel lead presence**, not voice recognition and not lyrics. Lead vocals are
mixed dead centre, so they survive in `mid = (L+R)/2` and largely cancel in
`side = (L−R)/2`; what is in the middle but not in the sides, within 600–2.6kHz, tracks the
singing well.

Evidence it is doing more than following volume: at ~230s every other band stays loud while
`v` drops to 0.22 — the instrumental break. Intro and outro sit near 0.00, the biggest chorus
peaks at 0.66.

It will not survive a mono mix, a centre-panned lead instrument, or a song where the vocal is
deliberately spread.

### Key roles

| Keys | Follow |
|---|---|
| 1–2 (top row) | the voice — warm near-white, so it reads as a different *kind* of thing |
| 3–4 | bass |
| 5–6 | highs |

Levels are scaled against the **recent** few seconds, not the whole song: absolute bass sits
at 0.94–1.00 for three minutes in this mix, so keys driven by raw level would simply stay on.
A flat window falls back to the absolute level — otherwise a signal pegged at maximum scales
to zero and the keys go dark exactly when the music is loudest.

Each key is rewritten only when its quantised value changes. Six keys plus the ring at ~80ms
a write is ~560ms, longer than a 504ms beat.

Sections carry an energy figure, which picks the look:

| Section energy | Style | Ring | Keys |
|---|---|---|---|
| < 0.25 | **ember** | dim slow breath | every 8 beats |
| < 0.45 | **pulse** | solid, gradient on downbeats | every 4 |
| < 0.65 | **sweep** | snake on downbeats | every 2 |
| ≥ 0.65 | **blaze** | complementary hues alternating each beat | every beat |

Color is HSL rather than a fixed palette: each section takes a base hue at least 60° from
its neighbour, drifting as the section plays so a long chorus does not sit on one color. An
accent is the *same hue, hotter* — a hue-shifted flash reads as a mistake, a brighter version
of the current color reads as a hit.

### Timing

Sync is **closed-loop** on QuickTime's playhead, with three corrections that each came from a
measurement:

| Measured | Correction |
|---|---|
| `play` returns before the playhead moves — an 88ms call, then a read of `0.000` | wait for the playhead to advance before anchoring, or the opening seconds run against a stopped clock |
| A playhead read costs **~100ms** round-trip | keep the fastest of several samples and credit each to the midpoint of its own round-trip |
| Awaiting that read in the beat loop stalled **a fifth of a 504ms beat** every 3s | re-anchor fire-and-forget, applying the result when it lands |
| A ring write takes **~86ms**, a key write ~79ms, plus audio output delay | fire every cue `leadMs` early |

Everything left over is a single constant, so there is one dial:

```bash
# countdown.leadMs in ~/Library/Application Support/OpenBoard/config.json
#   lights trailing the beat? raise it.  running ahead? lower it.
```

Default 110ms (`countdown.leadMs`).

The ring gets every beat; the keys change on the style's cadence. Painting everything every
beat cost ~245ms of a 504ms beat and the lights fell behind the music.

```bash
afconvert -f WAVE -d LEI16@8000 -c 1 <video> the-final-countdown/audio-8k.wav
node the-final-countdown/analyse-audio.cjs \
     the-final-countdown/audio-8k.wav the-final-countdown/analysis.json
```

`analysis.json` is committed (4.6KB); the video and WAV are not. Sync is **closed-loop**
against QuickTime's playhead rather than a start timestamp — over four minutes an
open-loop timer drifts, and it cannot tell that you paused, scrubbed or quit, so the lights
would dance on regardless.

## Develop

The app is a SwiftPM package in `mac/`, built without Xcode — SwiftUI, AppKit and IOKit
all compile against the Command Line Tools SDK.

```bash
cd mac
swift build
swift run OpenBoardTests      # a plain executable, not XCTest — see below
tools/build-app.sh --install  # assemble, sign, and put it in /Applications
tools/reload.sh               # rebuild, reinstall and relaunch in one step
```

(Those are `mac/tools/`, relative to the `cd mac` above.)

```
```

Tests are a **plain executable** rather than a `testTarget`. The Command Line Tools ship
an incomplete `Testing.framework` (no `lib_TestingInterop.dylib`) and no `xcodebuild`, so
swift-testing and XCTest are both unavailable without a full Xcode install. The harness
in `Sources/OpenBoardTests/Harness.swift` is about forty lines and prints the same
pass/fail summary.

Nothing in the suite touches hardware. Everything that could — device I/O, synthetic
input, AppleScript — is either injected or lives in the app target, which the test
executable does not link. That is deliberate: a test that types into whatever window is
focused is a test you cannot run while working.

**The suite is not enough on its own.** Every bug in this project's history was
invisible to a unit test: the device acknowledges a malformed request with `ok:1` and
then ignores it, so three separate bugs produced clean acknowledgements and a dark pad.
Verify against the real pad before believing a change works.

The original Node CLI was deleted once the port was complete. Its comments carried the
reasoning behind several constants that look arbitrary and are not, so that reasoning
was moved into the Swift sources rather than left in a directory nobody runs. `git log`
still has it.

## Author

OpenBoard is written and maintained by **Cam Wilson** — the app, the protocol work against
this pad, the session model, and everything in `mac/`.

## License

[MIT](LICENSE) — Copyright © 2026 Cam Wilson.

Two small pieces come from elsewhere and keep their own notices, as their licences
require: the original `v.oai.*` HID transport was first published by
[@pejmanjohn](https://github.com/pejmanjohn) in
[`codex-micro-light`](https://github.com/pejmanjohn/codex-micro-light) (MIT), and three
vendor brand marks identify the harnesses in the sidebar. Both are itemised in
[VENDORED.md](VENDORED.md) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
