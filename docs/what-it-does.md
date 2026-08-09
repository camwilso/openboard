# What OpenBoard does

[← back to the README](../README.md)

You run several Claude Code sessions at once. One of them is blocked on a permission
prompt right now, and you do not know which. Finding out means checking tabs.

OpenBoard puts that one bit of information — *is this session waiting on me?* — on a
physical key you can see without looking at a screen.

<p align="center">
  <img src="../assets/hero.jpg" width="760"
       alt="A Codex Micro beside a MacBook, keys lit in different colours">
</p>

## One key per session

Each Claude Code session claims one of the six Agent keys when it starts and **keeps it**
for as long as it runs. The key's colour is that session's state.

| State | Colour | What it means |
|---|---|---|
| idle | dim blue | The session is open, nothing running |
| working | blue, breathing | A turn is in progress |
| **awaiting** | **amber, breathing** | **Blocked on a permission prompt — this one needs you** |
| stalled | amber, shallow | Sitting at an idle prompt |
| done | green | The turn finished, and you have not been back yet |
| error | red, breathing | The turn failed |

**Green holds.** A session that finished while you were elsewhere is still green when you
look. It clears when you go back and send that session something — not on a timer, and
not when you merely glance at it. Status that expires on its own is status you learn to
distrust.

## Keys do not move

A session keeps its key. Keys are reused only after six newer sessions have cycled
through, and never one that is currently signalling *awaiting*.

This is deliberately unlike Codex's "most recent chats" mode, where your key number is
your rank in a live recency sort — so typing in one chat repaints four others. If the
meaning of key 3 changes while you are not looking, the board is worse than nothing,
because you will act on it anyway.

## The ring says it from across the room

<p align="center">
  <img src="../assets/ring.jpg" width="760"
       alt="The pad's outer ring lit green after a session finished">
</p>

Six small keys cannot be read from the other side of a room. The outer ring can.

It is **dark by default** and fires only when something changes:

| Event | Ring |
|---|---|
| a chat finishes | green, one slow lap |
| a chat stops to ask something | amber, one lap |
| a turn fails | red heartbeat |

A ring that is always lit is furniture. One that is dark until something happens is a
notification.

Failures get a different *shape*, not just a different colour. Peripheral vision reads
motion before hue, so a failure must never be mistakable for a completion — which is why
the error is a heartbeat and the completion is a lap.

## And in the menu bar

<p align="center">
  <img src="../assets/menubar.png" width="420"
       alt="Six coloured dots in the macOS menu bar mirroring the pad">
</p>

The same six states, as dots. Useful when the pad is out of sight, and the fastest way to
tell whether OpenBoard is running at all.

Click it for the full board:

<p align="center">
  <img src="../assets/popover.png" width="360"
       alt="The popover listing sessions with their states">
</p>

Each row is a session: what you asked it for, where it is running, how long it has been in
its current state. Anything blocked is called out at the top.

## Pressing a key goes there

Press an Agent key and OpenBoard brings that chat to the front. In Terminal it finds the
exact tab; in VS Code it reveals the panel already holding that conversation.

Nothing is ever *opened* by a jump. The extension reveals a panel it already has, and the
integrated-terminal case raises the app rather than opening a folder — an approximate jump
beats an unrequested one that rearranges your editor.

Where OpenBoard cannot confirm which chat is in front of you, it **refuses to answer a
prompt** rather than sending ⏎ at whatever happens to be there.

## Which sessions get a key

Only sessions running as a local process on your Mac, because that is where the hooks
execute and only a local process can reach the hardware.

| | |
|---|---|
| Terminal | yes |
| VS Code, integrated terminal | yes |
| VS Code, extension-hosted | yes |
| Subagents | no — six keys is a scarce budget |
| claude.ai/code, cloud, SSH | unreachable |

An unrecognised surface gets no key rather than quietly taking one.

---

**Next:** [Setting up](setup.md) · [Settings](settings.md) · [Troubleshooting](troubleshooting.md)
