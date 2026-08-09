# Other agents

[← back to the README](../README.md)

OpenBoard is built around Claude Code and knows about two other agents. They are not
equally supported, and the app says so rather than pretending otherwise — a harness that
can never turn a key green is not a harness with a small gap, it is a different product.

## Claude Code — what this was built for

Fully wired, and the only one tested at length. Both surfaces:

| | |
|---|---|
| **Terminal** | every state, and pressing a key finds the exact tab by its `tty` |
| **VS Code, extension-hosted** | every state, and a key reveals the panel already holding that conversation |
| **VS Code, integrated terminal** | every state; a key raises VS Code but cannot select a specific terminal — no API exposes that from outside |

Hooks install automatically. Setup edits `~/.claude/settings.json`, preserving every
unrelated setting and any other tool's hooks on the same events, and backs the file up
first.

This is the one that has been used daily for months, against real work, on real hardware.
Every bug the project has fixed came from that.

## Hermes Agent

Wired, and mostly works. One real gap:

> **No completion event.** Nothing in its shell hooks means "this turn ended", so a Hermes
> key never turns green.

Everything else lands — a key claims a slot, goes blue while working, amber when it needs
you. It simply never tells you it finished, which is half of what the board is for.

Setup is manual: OpenBoard shows you what to add rather than editing a file for you,
because its configuration is not a format that can be merged safely.

## Pi

Wired, with a bigger gap:

> **No approval event is documented**, so a Pi key never turns amber — the one state this
> board exists for.
>
> **In-process extensions only**, so setup is a file you add rather than a command
> OpenBoard can install.

A Pi key will show you that a session exists and that it is working. It will not tell you
when it is blocked on you, which is the question the whole thing was built to answer.

## This is where contributors would help most

Hermes and Pi were wired from their documentation, not from use. They are correct as far
as they go and barely exercised beyond that.

If you use either one daily, the useful contributions are:

**Tell us what actually happens.** The limitations above are read from docs. If Hermes has
a completion signal nobody noticed, or Pi surfaces approvals some other way, that changes
the product rather than patching it.

**A completion event for Hermes**, or evidence there genuinely is not one. Green holding
until you go back is the behaviour people notice most, and Hermes users do not have it.

**An approval signal for Pi.** Amber is the reason this exists.

**Another agent entirely.** Adding one is a `Harness` value: where its config lives, which
events it emits, which entry points may claim a key, and what it cannot do. See
`mac/Sources/OpenBoardKit/Harness.swift` — Claude Code's entry is the worked example, and
`limitations` is not optional decoration. A state that will never appear has to be
declared, because the alternative is a user waiting for a colour that is never coming.

Open an issue before writing much. The board's model — one key per session, keys that
never move, green that holds — constrains what a harness has to provide, and it is worth
checking the fit before building against it.

---

**Next:** [What it does](what-it-does.md) · [Setting up](setup.md) · [Settings](settings.md) · [Troubleshooting](troubleshooting.md)
