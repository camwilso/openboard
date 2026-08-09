# Troubleshooting

[← back to the README](../README.md)

Most problems are one of four things. The Device pane and the log will tell you which.

## Nothing lights at all

**The pad is on the wrong layer.** Per-key status renders only on **Layer 1**. Writes on
other layers succeed and simply do not appear, which makes this the most confusing failure
available — everything looks fine and nothing happens.

**Input Monitoring is not granted, or was granted without restarting.** macOS reads it at
launch. Settings → Device will say `denied`; grant it and restart OpenBoard.

**The pad is asleep.** Over Bluetooth, disconnecting is normal rather than exceptional.
Press any key on the pad to wake it.

## The keys light but never change

The hooks are not wired. Without them the pad connects, the board draws, and nothing ever
reports — which looks like the app working and the sessions being broken.

Settings → Device shows an orange panel with a **Repair hooks** button when this is the
case. After wiring them, **open a new Claude Code session**: hooks are read when a session
starts, so anything already running keeps going without them.

## A session appears but stays one colour

Same cause, narrower. That session started before the hooks existed. OpenBoard finds
running sessions by walking the process table, so it gets a key immediately — but nothing
inside it is reporting. Restart that session.

## Pressing a key does nothing

**Accessibility is not granted.** The board still lights correctly; only the keys that
*do* something stop working. It needs a restart after granting.

**The chat could not be confirmed.** Where OpenBoard cannot tell which session is in front
of you, it refuses to answer a prompt rather than sending ⏎ at whatever is there. In VS
Code this happens when two chats' names match for the first 25 characters, because the
window title is the only signal available.

## Automation will not grant

If setup says **"macOS has a refusal on record"**, someone answered No to that dialog
once. macOS never asks again. Turn OpenBoard on under System Settings → Privacy & Security
→ Automation.

QuickTime Player showing **when needed** is not a problem. It is used only by fun mode, and
macOS asks the first time you play it.

## Colours land on the wrong keys

The key order has not been confirmed, and your pad reports a different order from the one
every pad so far has. Settings → Device → **Recalibrate**. It paints six colours and asks
whether they are in that order.

## The board goes dark by itself

**The ChatGPT app is repainting the LEDs.** Codex drives the same hardware on its own
schedule. Either set Codex to *Custom assignments* and give it a subset of keys, or accept
periodic repaint. The two never interleave writes mid-message.

**An older copy of OpenBoard is still running.** The Device pane says *"something else has
it open"* when this happens. Quit the other one.

## Updates are not offered

**You built it yourself.** A self-signed build cannot verify the update feed's signature,
so the controls are hidden rather than offered and broken. `git pull` and rebuild.

**The check is off.** Settings → Device → Version.

## Where to look

```sh
~/Library/Logs/OpenBoard/app.log
```

Every diagnosis has started here. It records what the app saw at launch — permissions,
device state, hooks — and every paint since.

It contains session names, which are Claude Code's own summaries of what you are working
on, along with working-directory paths. It never leaves your machine, but it is worth
knowing before pasting it into an issue.

## Starting over

Setup can be re-run at any time from the menu bar popover or Settings → Device. To make
the app forget everything and behave like a fresh install:

```sh
rm -rf ~/Library/Application\ Support/OpenBoard
```

Your permissions and hooks are not in there — those are macOS's and Claude Code's
respectively — so this resets colours, the pad name and the key order only.

---

**Next:** [What it does](what-it-does.md) · [Setting up](setup.md) · [Settings](settings.md)
