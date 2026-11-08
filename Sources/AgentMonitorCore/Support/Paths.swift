import CodexHookKit
import Foundation

public enum Paths {
    public static var home: String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }

    /// Where the Codex hook helper drops `<session_id>.json` state records.
    public static var codexHookStateDir: String { CodexHookKit.stateDir }
}
