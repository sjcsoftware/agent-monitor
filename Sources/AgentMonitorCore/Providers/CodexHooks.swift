import CodexHookKit
import Foundation

/// Codex lifecycle hooks (GUIDE §4.2): mapping, state records, and hooks.json (un)installation.
public enum CodexHooks {
    public static let helperName = CodexHookKit.helperName
    public static let events = CodexHookKit.events
    public typealias Record = CodexHookKit.Record

    public static func state(event: String, toolName: String?) -> SessionState? {
        CodexHookKit.state(event: event, toolName: toolName).flatMap(SessionState.init(rawValue:))
    }

    public static func state(of record: Record) -> SessionState? { SessionState(rawValue: record.state) }

    public static func waiting(for record: Record) -> String {
        guard record.state == SessionState.input.rawValue else { return "" }
        return record.event == "PermissionRequest" ? "permission" : "question"
    }

    public static func handle(input: Data, dir: String = Paths.codexHookStateDir, now: Double = Date().timeIntervalSince1970) {
        CodexHookKit.handle(input: input, dir: dir, now: now)
    }

    public static func read(threadId: String, dir: String = Paths.codexHookStateDir) -> Record? {
        CodexHookKit.read(threadId: threadId, dir: dir)
    }

    // MARK: - hooks.json

    public enum InstallError: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self {
            case .unreadable(let path): return "\(path) is not valid JSON; not touching it."
            }
        }
    }

    public static func hooksFile(home: String = Paths.home) -> String {
        (home as NSString).appendingPathComponent(".codex/hooks.json")
    }

    private static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(helperName) == true
    }

    private static func load(_ path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [:] }
        guard let obj = JSON.object(data) else { throw InstallError.unreadable(path) }
        return obj
    }

    private static func save(_ obj: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func isInstalled(path: String = hooksFile()) -> Bool {
        guard let obj = try? load(path), let hooks = obj["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [Any]) ?? []).contains(where: isOurs)
            }
        }
    }

    /// Adds one group per event pointing at `command`; existing user hooks are left untouched and keep their order.
    /// Returns `true` if the file changed.
    @discardableResult
    public static func install(command: String, path: String = hooksFile()) throws -> Bool {
        var obj = try load(path)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            var groups = hooks[event] as? [Any] ?? []
            var found = false
            for (i, g) in groups.enumerated() {
                guard var group = g as? [String: Any], var list = group["hooks"] as? [Any] else { continue }
                for (j, h) in list.enumerated() where isOurs(h) {
                    found = true
                    if var hook = h as? [String: Any], hook["command"] as? String != command {
                        hook["command"] = command
                        list[j] = hook
                        group["hooks"] = list
                        groups[i] = group
                        changed = true
                    }
                }
            }
            if !found {
                groups.append(["hooks": [["type": "command", "command": command]]])
                changed = true
            }
            hooks[event] = groups
        }
        guard changed else { return false }
        obj["hooks"] = hooks
        try save(obj, to: path)
        return true
    }

    /// Removes only Agent Monitor's hook entries (and groups/events left empty by that).
    @discardableResult
    public static func uninstall(path: String = hooksFile()) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var obj = try load(path)
        guard var hooks = obj["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for g in groups {
                guard var group = g as? [String: Any], let list = group["hooks"] as? [Any] else {
                    kept.append(g)
                    continue
                }
                let filtered = list.filter { !isOurs($0) }
                if filtered.count == list.count { kept.append(g); continue }
                changed = true
                if !filtered.isEmpty {
                    group["hooks"] = filtered
                    kept.append(group)
                }
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        guard changed else { return false }
        obj["hooks"] = hooks
        try save(obj, to: path)
        return true
    }
}
