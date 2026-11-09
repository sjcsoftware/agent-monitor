import Darwin
import Foundation

/// Guarantees one running app per user. The kernel arbitrates `flock`, so simultaneous launches
/// can't both win, and it drops the lock when the holder dies, so a crash can't leave it stale.
public enum InstanceLock {
    public enum Outcome: Equatable {
        /// This process holds the lock until it exits, as long as `fd` stays open.
        case acquired(fd: Int32)
        case alreadyHeld
        /// The lock file couldn't be opened or locked.
        case unavailable(errno: Int32)
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/AgentMonitor/instance.lock"
    }

    public static func acquire(at path: String) -> Outcome {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // O_CLOEXEC: a child inheriting this descriptor would keep the lock alive after we exit.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            return failure == EWOULDBLOCK ? .alreadyHeld : .unavailable(errno: failure)
        }
        return .acquired(fd: fd)
    }
}
