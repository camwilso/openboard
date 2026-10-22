import Foundation

/**
 Jumping to a Warp tab.

 Warp has no AppleScript dictionary and draws its own tabs, so neither tty walk that
 reaches Terminal and iTerm2 can select anything in it. What it does have, since
 v0.2026.05.27, is a per-pane link: every shell Warp starts carries
 `WARP_FOCUS_URL=warp://session/<32 hex>` in its environment, and opening that link
 makes Warp find the pane in every window and tab, raise the window and focus the
 split — with no Automation or Accessibility grant. A `claude` started from that shell
 inherits the variable, so the session's own process answers the question.

 Read from the process at jump time rather than carried in the hook payload: a link
 that cannot change while the pane exists is not worth a field in every event, and
 `KERN_PROCARGS2` is the same source `ps -E` reads, without the subprocess.
 */
public enum WarpFocus {
    /// Each release channel is its own bundle, with its own URL scheme.
    public static let bundleIDs = [
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "dev.warp.Warp-Dev",
        "dev.warp.Warp-OSS",
    ]

    public static let variable = "WARP_FOCUS_URL"

    /// The link a session's process carries, if it is one Warp would act on.
    public static func url(forPID pid: Int) -> URL? {
        guard let raw = environmentValue(ofPID: pid, key: variable), isSessionLink(raw)
        else { return nil }
        return URL(string: raw)
    }

    /// `warp://session/<32 lowercase hex>` on any channel's scheme. Checked because the
    /// value comes from another process's environment, and `open` on anything else
    /// would be a confident wrong answer of the kind `Focus` exists to avoid.
    public static func isSessionLink(_ string: String) -> Bool {
        string.range(
            of: "^warp(preview|dev|oss)?://session/[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil
    }

    /// One variable from another process's environment, via `sysctl(KERN_PROCARGS2)`.
    /// Readable for the user's own processes, which is every session this app can see.
    public static func environmentValue(ofPID pid: Int, key: String) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc as Int32, the executable path, NUL padding, then argc
        // NUL-terminated arguments, then NUL-terminated `KEY=value` strings.
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var offset = MemoryLayout<Int32>.size
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }
        var skipped = 0
        while skipped < argc, offset < size {
            while offset < size, buffer[offset] != 0 { offset += 1 }
            offset += 1
            skipped += 1
        }

        let prefix = Array("\(key)=".utf8)
        while offset < size {
            var end = offset
            while end < size, buffer[end] != 0 { end += 1 }
            if end == offset { break }
            let entry = buffer[offset..<end]
            if entry.starts(with: prefix) {
                return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
            offset = end + 1
        }
        return nil
    }
}
