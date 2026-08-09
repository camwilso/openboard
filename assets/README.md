# Screenshots

Five images: two photographs and three window captures.

| File | What |
|---|---|
| `hero.jpg` | The pad beside a MacBook, keys lit in different states — the README's lead |
| `ring.jpg` | The outer ring mid-lap after a session finished |
| `popover.png` | The menu bar popover — four live sessions, two waiting |
| `setup.png` | Guided setup, three of five complete |
| `settings.png` | Settings → Board, mapping what each key does |

The two photos are JPEG and the three captures are PNG, deliberately. A photograph as
PNG is several megabytes for no visible gain; a UI capture as JPEG smears text. Both were
resized to 1800px wide, which is 2x what GitHub renders and keeps the folder under 2MB.

## How the captures were taken

Not with `⌘⇧4`. A window grabbed with `screencapture -l<id>` has no backdrop, and the
app's Liquid Glass samples what is behind it — so the popover came out flat grey, which
is not what anyone sees.

They are screen-region captures with every other app hidden, which gives the glass a real
desktop to sample. `mac/tools/` has no helper for this; it was a one-off:

```sh
# window ids and bounds
swift windows.swift OpenBoard        # CGWindowListCopyWindowInfo

# hide everything else, then
screencapture -x -R<x,y,w,h> out.png
```

The setup window was captured by launching with a scratch state directory, which makes it
a first launch and opens setup by itself:

```sh
open -a OpenBoard --env OPENBOARD_HOME=/tmp/scratch --env CLAUDE_CONFIG_DIR=/tmp/scratch-claude
```

## If you retake them

**Check the session names first.** The popover shows Claude Code's own summaries of what
you are working on, and these go in a public README. The current `popover.png` shows four
titles, all about this project — worth a look before it ships, and worth using a scratch
project if any of them name something private.

**Keep the wallpaper quiet.** The glass samples it, so a busy desktop shows through and
competes with the content.

**Same appearance across all of them.** Mixed light and dark reads as screenshots of
different apps.
