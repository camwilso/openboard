# Setting up

[← back to the README](../README.md)

## Install

```sh
brew install --cask camwilso/tap/openboard
```

Or download the zip from [Releases](https://github.com/camwilso/openboard/releases),
unzip, and drag it to Applications. It is signed and notarized, so it opens normally —
no right-click-Open, no trip to Security settings.

## First launch

Open OpenBoard and setup appears by itself. It has **no Dock icon** — it lives in the menu
bar, so the setup window is the only thing you will see at first.

<p align="center">
  <img src="../assets/setup.png" width="520"
       alt="Guided setup, three of five steps complete">
</p>

Five things, none of which take long.

### Input Monitoring

Reading the pad. Without it nothing lights and no key press is seen — this is the one that
makes OpenBoard work at all.

**Takes effect after OpenBoard restarts.** macOS reads this at launch, so granting it
while the app is running appears to do nothing. There is a **Restart OpenBoard** button in
the setup window for exactly this.

### Accessibility

Typing snippets, sending ⏎ and ⎋, and scrolling with the dial. Also needs a restart.

Without it the board still lights correctly; only the keys that *do* something stop
working.

### Automation

Driving System Events, which the key actions use. OpenBoard asks macOS directly here — no
trip to System Settings.

If you see *"macOS has a refusal on record"*, you or someone previously answered No to
that dialog. macOS never asks twice, so the button changes to **Open** and you turn it on
under System Settings → Privacy & Security → Automation.

QuickTime Player is listed separately and reads **when needed**. It is only used by fun
mode, and macOS asks the first time you play it. Nothing is wrong.

### Key order

Confirms which physical key is slot 1. The board assumes the order every pad so far
reports, so this takes ten seconds and usually just confirms what is already true.

It matters because colours and bindings are set per *slot*. If slot 3 is not the key you
think it is, everything you configure lands somewhere else.

The check paints six colours on the pad and asks one question: are they in that order?

### Claude Code hooks

Adds OpenBoard to `~/.claude/settings.json` so your sessions report what they are doing.
Every unrelated setting is preserved, any other tool's hooks on the same events survive,
and the file is backed up beside itself first.

**Hooks are read when a session starts.** Sessions already open keep running without them
— they will get a key immediately, because OpenBoard walks the process table, but they
will never change colour. Open a new session to see it work.

## The pad itself

Two things setup cannot do for you:

- **Pair the Codex Micro** with this Mac, over Bluetooth or USB
- **Keep it on Layer 1** — per-key status renders only there. Writes on other layers
  succeed and simply do not appear, which is the most confusing possible failure

## Checking afterwards

Settings → Device shows the whole picture at any time:

<p align="center">
  <img src="../assets/device.png" width="720"
       alt="Settings Device pane: connection, permissions, startup, version">
</p>

Connection state, every permission with a button to the right settings pane, whether the
key order has been confirmed and when, and which build you are on.

## Keeping it running

Turn on **Open OpenBoard at login**, in the same pane. A board you have to remember to
launch is not an ambient board.

---

**Next:** [What it does](what-it-does.md) · [Settings](settings.md) · [Troubleshooting](troubleshooting.md)
