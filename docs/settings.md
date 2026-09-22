# Settings

[← back to the README](../README.md)

Three panes. Every change saves immediately and repaints the board, so there is no save
button to forget.

Open it from the menu bar popover, or **hold the dial** on the pad.

## Board — what each key does

<p align="center">
  <img src="../assets/settings.png" width="760"
       alt="The Board pane, showing the pad with live key colours">
</p>

The pad, drawn as it actually is, with the six Agent keys showing their current colours.
Click any key to see what it does and change its keycap.

The **name** you give the pad is used everywhere OpenBoard refers to it — the popover
header, the Device pane, the disconnected message. Worth setting if you have more than one
Mac.

Every key other than the six Agent keys is yours to bind. The defaults:

| | |
|---|---|
| approve / reject | answer the permission prompt in the session you are looking at |
| type snippet | send a saved piece of text |
| new Terminal tab | what it says |
| tap to dictate | push-to-talk |
| fun mode | the party trick, see below |
| the dial | press for the popover, hold for Settings |

Two more are there to bind but are not defaults. **send ⏎** submits whatever you are
typing, wherever the cursor is. **custom shortcut** replays any keyboard chord you record —
pick it, click *Record shortcut*, press the keys. On the action keys you can choose whether
the pad key taps the chord or holds it down for as long as you hold the key, which is how a
push-to-talk hotkey wants to be driven; the dial and the joystick only tap.

## Colors — states, laps and shows

Every state, with its colour, its effect and its brightness:

| State | When |
|---|---|
| idle | session open, nothing running |
| working | a turn is running |
| awaiting | blocked on a permission prompt |
| stalled | an idle prompt fired |
| done | finished, and you have not been back |
| error | the turn failed |
| ended | session closed |

The ▶ beside each row plays it on the pad. A colour at 55% on an emissive key is not a
swatch at 55% opacity, so the only honest preview is the hardware.

**Keep finished sessions lit until you go back** is on by default and is the behaviour
most worth understanding: green holds until you send that session something, so work that
finished while you were away is still visible when you return.

<p align="center">
  <img src="../assets/shows.png" width="760"
       alt="The ring section: which events fire a lap, and ten shows you can play">
</p>

### Laps

Which events fire the ring. All three on by default — a chat finishing, one needing you,
one failing.

### Shows

Ten built-in animations you can fire at any time. The first three are the ones the board
uses on its own; the rest are there because the hardware can:

| | |
|---|---|
| Completion lap | green snake, then a slow fade — 5.0s |
| Question lap | amber snake, then a fade — 3.9s |
| Error heartbeat | red double-beats — 3.0s |
| Rainbow spin | the full hue wheel, fast — 6.0s |
| Police lights | red and blue, alternating hard — 3.1s |
| Snake chase | a slow snake through five colours — 13.0s |
| Sunrise | deep red climbing to daylight — 6.2s |
| Heartbeat | two quick beats, then a rest, repeating — 4.3s |
| Strobe | white, hard on and off — 1.3s |
| Slow breathe | cyan to magenta, long and calm — 8.0s |

Playing one takes over the ring briefly, then the real board comes back.

### Fun mode

Takes over the whole pad — status included — for the length of a song, driving the lights
against a beat grid derived from the audio. See
[the-final-countdown](../the-final-countdown/) for how songs are mapped and how to add
your own.

## Device — permissions, startup and version

<p align="center">
  <img src="../assets/device.png" width="760"
       alt="The Device pane: connection, permissions, key order and version">
</p>

**Connection** at the top: what the pad is called, and whether it is live.

**Permissions**, each with an Open button that lands on the right System Settings pane.
Automation can be granted in place. Every permission takes effect after OpenBoard
restarts, which the pane says because a grant that appears to do nothing is the most
common reason people conclude the app is broken.

**Key order** shows whether it has been confirmed and when. Three states, and the middle
one matters: *not checked* (running on the assumed order), *checked — the standard order*,
or *custom order recorded* with the slots that moved.

**Version** shows the build and when it last checked for an update. Updates install in
place, which is what keeps permissions and hooks working — see below.

**Files** reveals your settings and log in Finder.

## Updates

OpenBoard checks once a day and installs updates in place. Take them: replacing the bundle
where it stands is what preserves the Input Monitoring and Accessibility grants, the login
item, and the hook paths in `~/.claude/settings.json`. Downloading a fresh copy and
dragging it over the old one usually works and sometimes does not.

Turn the daily check off, or run one now, in Settings → Device → Version.

A build you compiled yourself cannot update itself — the feed's signature will not verify
against a key it does not have — so the controls are hidden rather than offered and broken.

---

**Next:** [What it does](what-it-does.md) · [Setting up](setup.md) · [Troubleshooting](troubleshooting.md)
