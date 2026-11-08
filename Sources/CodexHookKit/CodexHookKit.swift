import Foundation

/// The Codex lifecycle-hook protocol shared by the `agent-monitor-hook` helper and the app.
/// Deliberately Foundation-only so the helper stays tiny and starts instantly.
public enum CodexHookKit {
    public static let helperName = "agent-monitor-hook"
    public static let questionTools: Set<String> = ["request_user_input", "ask_user", "AskUserQuestion"]
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "SubagentStart", "Stop", "Interrupt",
    ]

    /// `{state, event, ts}` written to `<runtime dir>/agents/codex/<session_id>.json`.
    public struct Record: Codable, Equatable {
        /// `ready` | `working` | `input` | `done`
        public var state: String
        public var event: String
        public var ts: Double

        public init(state: String, event: String, ts: Double) {
            self.state = state
            self.event = event
            self.ts = ts
        }
    }

    /// State for a hook event; `nil` for events that don't change state.
    public static func state(event: String, toolName: String?) -> String? {
        switch event {
        case "SessionStart": return "ready"
        case "UserPromptSubmit", "PostToolUse", "SubagentStart": return "working"
        case "PreToolUse": return questionTools.contains(toolName ?? "") ? "input" : "working"
        case "PermissionRequest": return "input"
        case "Stop", "Interrupt": return "done"
        default: return nil
        }
    }

    /// The per-user temporary directory (`/var/folders/…/T/`), independent of `$TMPDIR`.
    public static var runtimeDir: String {
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 { return String(cString: buf) }
        return NSTemporaryDirectory()
    }

    public static var stateDir: String {
        (runtimeDir as NSString).appendingPathComponent("agents/codex")
    }

    /// One JSON event → atomic state file (temp + rename). Never throws, prints nothing.
    public static func handle(input: Data, dir: String = stateDir, now: Double = Date().timeIntervalSince1970) {
        guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let event = obj["hook_event_name"] as? String,
              let rawId = obj["session_id"] as? String else { return }
        let id = String(rawId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        guard !id.isEmpty else { return }
        let path = (dir as NSString).appendingPathComponent("\(id).json")
        if event == "SessionEnd" {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        guard let state = state(event: event, toolName: obj["tool_name"] as? String),
              let data = try? JSONEncoder().encode(Record(state: state, event: event, ts: now)) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = path + ".\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else { return }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }

    public static func read(threadId: String, dir: String = stateDir) -> Record? {
        let path = (dir as NSString).appendingPathComponent("\(threadId).json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}
