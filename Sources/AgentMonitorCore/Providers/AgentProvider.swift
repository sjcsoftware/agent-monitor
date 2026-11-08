import Foundation
import os

public protocol AgentProvider: AnyObject {
    var kind: AgentKind { get }
    /// Never throws; returns `[]` when the agent can't be read.
    func sessions(now: Double) -> [Session]
}

let log = Logger(subsystem: "com.sjcsoftware.agent-monitor", category: "providers")

/// Logs each distinct message once per process lifetime.
enum LogOnce {
    private static var seen = Set<String>()
    private static let lock = NSLock()

    static func warn(_ message: String) {
        lock.lock()
        let fresh = seen.insert(message).inserted
        lock.unlock()
        if fresh { log.warning("\(message, privacy: .public)") }
    }
}

/// Context-window fallbacks when an agent doesn't report one (GUIDE §3).
enum ContextWindow {
    static let claude = 200_000
    static let claudeLarge = 1_000_000
    static let codex = 272_000
    static let copilot = 200_000
}
