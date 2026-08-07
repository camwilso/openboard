import Foundation

/**
 A log file, because a menu bar app has nowhere else to speak.

 There is no terminal attached, no window to print into, and `os_log` needs Console
 open and a predicate to find anything. Meanwhile every interesting failure here is
 environmental — a permission not granted, a device that vanished, a write refused —
 and the app's only way to report is a color in a menu bar, which cannot say *why*.

 The Node version had exactly this file and it is what made every problem in this
 project tractable. Rebuilding it in Swift was overdue: several rounds of diagnosis
 were spent inferring state from the outside because the app could not simply say
 what it saw.

 Bounded, since it runs for as long as the user is logged in.
 */
public enum Log {
    private static let queue = DispatchQueue(label: "com.openboard.log")
    private static let maxBytes = 512 * 1024

    /// `~/Library/Logs/OpenBoard/app.log` — where Console.app looks, and where "send me
    /// your logs" already points.
    public static var url: URL {
        AppPaths.logs().appendingPathComponent("app.log")
    }

    public static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let url = Self.url
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                try? Data().write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Log a transition only when it actually changes, so a 10s poll does not fill
    /// the file with "still fine".
    /**
     Log only when the value differs from last time, and hand back what to remember.

     Returns the new value rather than taking `inout`. The `inout` form took a dynamic
     exclusive access to a *class property*, and every caller here is inside an async
     `@MainActor` method — which is precisely the shape Swift's exclusivity enforcement
     traps on. It crashed the app on launch with `swift_beginAccess`, from the resident
     loop, every few seconds.

     Returning the value moves the write to the call site, where it is an ordinary
     assignment with no access spanning anything.
     */
    public static func changed<T: Equatable>(
        _ label: String,
        last previous: T?,
        to current: T
    ) -> T? {
        guard previous != current else { return previous }
        write("\(label): \(current)")
        return current
    }
}
