# Homebrew cask for OpenBoard.
#
# This file is the source of truth; the copy Homebrew reads lives in the tap repo at
#   github.com/camwilso/homebrew-tap  →  Casks/openboard.rb
# Copy it across when cutting a release, or let the release workflow do it.
#
# Why a personal tap rather than homebrew-cask proper: the main repo requires a
# notability threshold (roughly 75 stars / 30 forks / 30 watchers) before it will take
# a cask. A tap works from the first release and the install line is barely longer.
#
#   brew install --cask camwilso/tap/openboard
#
cask "openboard" do
  version "0.1.0"
  sha256 "945702d685576e44990e372934cf939ec0a2c4bb1149efb8bf57b63a7210ee93"

  url "https://github.com/camwilso/openboard/releases/download/v#{version}/OpenBoard-#{version}.zip",
      verified: "github.com/camwilso/openboard/"
  name "OpenBoard"
  desc "Drives a Codex Micro's Agent-key LEDs from your Claude Code sessions"
  homepage "https://openboardapp.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself through Sparkle, in place — which is the only way it keeps
  # its Input Monitoring and Accessibility grants, since macOS ties those to the bundle
  # path and signature. Telling Homebrew so stops `brew upgrade` from replacing the
  # bundle underneath it and costing the user both.
  auto_updates true

  depends_on macos: :sonoma

  app "OpenBoard.app"

  uninstall quit: "com.openboardapp.mac"

  # Not in `uninstall`, because these hold real user configuration — key colours, the
  # pad's calibration — and `brew uninstall` should not silently discard them.
  # `brew uninstall --zap` is the explicit "remove everything" and this is what it takes.
  zap trash: [
    "~/Library/Application Support/OpenBoard",
    "~/Library/Logs/OpenBoard",
    "~/Library/Preferences/com.openboardapp.mac.plist",
    "~/Library/Caches/com.openboardapp.mac",
  ]

  caveats <<~EOS
    Open OpenBoard and it will walk you through setup — permissions, key order,
    and the Claude Code hooks. It has no Dock icon; it lives in the menu bar.

    Two things it cannot do for you, both on the pad itself:
      · pair the Codex Micro with this Mac, over Bluetooth or USB
      · keep it on Layer 1 — per-key status renders only there

    Hooks are read when a Claude Code session starts, so open a new one to see
    the keys light. Sessions already running will not report until they restart.

    Before uninstalling, turn the hooks off in Settings → Device. Deleting the app
    without doing that leaves eight entries in ~/.claude/settings.json pointing at
    a binary that is gone, and every session will try to run it on every event.
  EOS
end
