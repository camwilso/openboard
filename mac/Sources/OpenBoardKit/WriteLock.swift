import Foundation

/**
 The cross-process mutex for HID writes.

 **The path is deliberately not ours.** It matches upstream's
 `$TMPDIR/codex-micro-light-<uid>/hid-write.lock` exactly, because both tools must
 contend for the *same* mutex — an RPC message spans several 64-byte reports, and two
 writers taking turns mid-message interleaves them into garbage the firmware silently
 drops. A project-specific path would look tidier and would make the two tools
 invisible to each other, which is the entire failure this prevents.

 Do not "fix" this to `com.openboard.*`. The Node version carries the same warning and
 has done since it was vendored.

 Implemented with `flock(2)` on a lock file rather than the Node version's helper
 subprocess, which only existed because Node has no portable file locking. The lock
 file itself is never truncated or removed: another process may be holding a
 descriptor to it, and replacing the inode releases their lock without their knowing.

 ## The descriptor is a local, not actor state

 It used to be a stored property, which deadlocked the app *and* every other writer on
 the machine within minutes.

 Actors are reentrant: while `withLock` is suspended awaiting `body()`, another call
 can enter and run `acquire()`, overwriting the stored descriptor. The first call's
 `release()` then closes the *second* call's descriptor, and the original file
 descriptor is leaked — still open, still holding its flock, for the life of the
 process. Nothing can ever take the lock again, including the process that leaked it.

 The symptom was "something else owns the lights": OpenBoard could not paint, and
 neither could the Node CLI, which timed out after 20s waiting for a writer that was
 never going to let go.

 Keeping the descriptor local to each call makes the leak structurally impossible.
 */
public actor HIDWriteLock {
    public static let shared = HIDWriteLock()

    /// Held in-process so concurrent callers queue instead of fighting over `flock`
    /// and timing each other out. The file lock is still what coordinates with
    /// *other* processes.
    private var busy = false

    public init() {}

    public static func defaultLockPath() -> URL {
        let uid = getuid()
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-micro-light-\(uid)")
            .appendingPathComponent("hid-write.lock")
    }

    /// Run `body` with the lock held, releasing it however `body` ends.
    ///
    /// - Parameter timeout: how long to wait for another writer. Upstream defaults to
    ///   20s; a status light is best-effort and must never block a session, so
    ///   callers pass something far shorter.
    public func withLock<T>(
        timeout: TimeInterval = 2.0,
        _ body: () async throws -> T
    ) async throws -> T {
        // Wait out any in-process holder first. Two of our own tasks racing for the
        // same file lock would just time each other out for no reason.
        let deadline = Date().addingTimeInterval(timeout)
        while busy {
            guard Date() < deadline else { throw LockError.busy(timeout) }
            try? await Task.sleep(for: .milliseconds(10))
        }

        busy = true
        let descriptor = try acquire(timeout: timeout)
        defer {
            release(descriptor)
            busy = false
        }
        return try await body()
    }

    /// Returns the locked descriptor. Deliberately not stored on the actor — see the
    /// note above about reentrancy.
    private func acquire(timeout: TimeInterval) throws -> Int32 {
        let url = Self.defaultLockPath()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // O_CREAT without O_TRUNC: truncating would be pointless (the file has no
        // contents) and reopening is how you accidentally drop someone else's lock.
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw LockError.cannotOpen(String(cString: strerror(errno))) }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            guard errno == EWOULDBLOCK else {
                let message = String(cString: strerror(errno))
                close(descriptor)
                throw LockError.failed(message)
            }
            guard Date() < deadline else {
                close(descriptor)
                throw LockError.busy(timeout)
            }
            // Polling rather than blocking on LOCK_EX so the timeout is honoured.
            usleep(15_000)
        }
    }

    private func release(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public enum LockError: Error, LocalizedError {
        case cannotOpen(String)
        case failed(String)
        case busy(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case let .cannotOpen(detail): "could not open the HID write lock: \(detail)"
            case let .failed(detail): "HID write lock failed: \(detail)"
            case let .busy(seconds):
                "another Codex Micro writer held the lock for more than \(Int(seconds))s"
            }
        }
    }
}
