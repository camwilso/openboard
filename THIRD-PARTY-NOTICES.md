# Third-party notices

OpenBoard is Copyright © 2026 **Cam Wilson**, distributed under the MIT licence in
[LICENSE](LICENSE). Everything in this repository is his work except the items below,
which are third-party and carry their own terms.

They are listed because their licences require it, and because it is the honest record
of what came from where. See [VENDORED.md](VENDORED.md) for exactly what was taken and
how it was changed.

---

## codex-micro-light

https://github.com/pejmanjohn/codex-micro-light

Vendored, and since reimplemented in Swift as `mac/Sources/OpenBoardKit/HIDDevice.swift`,
`CodexProtocol.swift` and `WriteLock.swift`.

```
MIT License

Copyright (c) 2026 Pejman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Not redistributed

The native `node-hid` binding is **loaded at runtime** from Work Louder Input or the ChatGPT desktop
app, whichever is already installed on the user's Mac. No Work Louder or OpenAI binary is copied into
or distributed with this project.

Codex, Codex Micro, ChatGPT, OpenAI, Work Louder, Claude, and Claude Code are trademarks of their
respective owners. This project is not affiliated with or endorsed by any of them.

---

## Provider icons

Vendored from [CodexBar](https://github.com/steipete/CodexBar)'s bundled
`ProviderIcon-*.svg` set as `mac/Sources/OpenBoardKit/ProviderIcons.swift`.

Two marks CodexBar does not carry come from their owners instead: Pi's from `pi.dev`'s
favicon, as vector paths in the same file, and Hermes Agent's from
`hermes-agent.nousresearch.com/favicon.ico`, embedded as a PNG in `ProviderRasters.swift`
because it is a portrait rather than a shape.

Each mark belongs to its owner — Anthropic, Nous Research, Earendil — and appears here
only to identify that product in the list of harnesses. No affiliation or endorsement is
implied.
