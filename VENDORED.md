# Vendored code

OpenBoard is Copyright © 2026 Cam Wilson. This file is the record of the parts that are
not — what was taken, from where, and how it was changed since.

## Upstream

| | |
|---|---|
| Source | https://github.com/pejmanjohn/codex-micro-light |
| Commit | `029bc10` — "Add ambient ring control and scope spatial effects" |
| Retrieved | 2026-07-28 |
| License | MIT — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) |

## What we took

| Upstream path | Here | Notes |
|---|---|---|
| `scripts/lib/codex-micro-hid.cjs` | `mac/Sources/OpenBoardKit/HIDDevice.swift`, `CodexProtocol.swift` | HID transport + RPC framing |
| `scripts/lib/hid-write-lock.cjs` | `mac/Sources/OpenBoardKit/WriteLock.swift` | `lockf`-based write mutex |

Both were vendored as CommonJS first and have since been reimplemented in Swift. The
protocol constants, the report framing and the lock path are unchanged — they describe
somebody else's firmware and are not ours to vary — so the attribution stands.

## What we deliberately did not take

**`scripts/lib/resolve-agent-slot.cjs`** — resolves a slot from `CODEX_THREAD_ID` by reading
`~/.codex/.codex-global-state.json` and querying `~/.codex/state_5.sqlite`. Entirely Codex-specific,
and its recency-rank model is the behaviour this project exists to replace. `SessionRegistry`
supersedes it.

Also skipped: the Codex plugin packaging (`.codex-plugin/`, `skills/`, `agents/openai.yaml`) and the
`$setmicrolight` CLI, whose argument surface is shaped around Codex task resolution.

## Provider icons

| | |
|---|---|
| Source | `CodexBar.app/Contents/Resources/ProviderIcon-claude.svg`, and Pi's own favicon |
| Here | `mac/Sources/OpenBoardKit/ProviderIcons.swift` |
| Also | `ProviderRasters.swift` — Hermes Agent's favicon, embedded as a PNG |

The converter reads an installed copy of CodexBar, so it is not in this repository; the
marks it produced are, above. Compiled to vector paths by the same route the keycaps take — there is no asset catalog in a Command Line Tools build, and a vector tints with
the view, which the greyed-out rows depend on.

These are **third-party brand marks**: the Claude mark is Anthropic's, the Codex mark
OpenAI's, and so on down the list. They are used to identify each vendor's own product
in a list of agents found on the machine, which is what a mark is for. They are not
this project's to license, and nothing here implies any of those vendors endorse it.

## Why vendor rather than depend

- We need roughly a third of the package and are dropping its central abstraction.
- The underlying `v.oai.*` protocol is private and undocumented. When it breaks we need to patch the
  transport immediately, not wait on an upstream release.
- It is JavaScript and this app is Swift, so there was never a dependency to take — only knowledge.

## Local modifications

Keep this list current — it is what makes upstream diffs tractable.

- **Lock path is shared with upstream, intentionally.** `WriteLock.swift` keeps upstream's default of
  `$TMPDIR/codex-micro-light-<uid>/hid-write.lock`. Both tools must contend for the *same* mutex or
  their multi-report HID messages can interleave mid-message. Do not "fix" this to a project-specific
  path.
- Error strings referencing `setmicrolight` renamed for this project's diagnostics.
- Reimplemented in Swift: IOKit directly rather than a native node binding, `async` writes, and
  typed errors. The wire format is byte-identical.

## Tracking upstream

```bash
git clone --depth 1 https://github.com/pejmanjohn/codex-micro-light /tmp/cml
# No longer a textual diff — read these against CodexProtocol.swift and WriteLock.swift.
less /tmp/cml/plugins/codex-micro-light/skills/setmicrolight/scripts/lib/codex-micro-hid.cjs
less /tmp/cml/plugins/codex-micro-light/skills/setmicrolight/scripts/lib/hid-write-lock.cjs
```

Watch specifically for changes to the `v.oai.thstatus` / `v.oai.rgbcfg` method names, the report
framing constants (`REPORT_ID`, `RPC_CHANNEL`, `MAX_CHUNK_SIZE`), and the native binding search paths
— those are the parts most likely to shift under a vendor update.
