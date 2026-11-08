import Foundation

/// OpenAI Codex TUI: live `codex` processes matched to threads in `~/.codex/state_5.sqlite`,
/// rollout JSONL for state/tokens, and lifecycle-hook records for approvals (GUIDE §4.2).
public final class CodexProvider: AgentProvider {
    public let kind = AgentKind.codex
    private let home: String
    private let procs: ProcessInspecting
    private let hookDir: String
    private let windowTitles: ((Int32) -> [String])?
    private let refreshTitles: (() -> Void)?
    private var rollouts: [Int32: Rollout] = [:]
    private var columns: Set<String>?
    private let config = FileCache<(model: String?, effort: String?)> { CodexProvider.parseConfig($0) }
    private let index = FileCache<[String: String]> { CodexProvider.parseIndex($0) }

    static let excludedSubcommands: Set<String> = ["app-server", "exec", "e", "mcp-server", "mcp", "login", "logout", "proto"]
    static let attentionTitle = try! NSRegularExpression(pattern: "action required|approval|needs? (your )?(input|approval)", options: [.caseInsensitive])
    private static let effortPattern = try! NSRegularExpression(pattern: "\"(?:reasoning_)?effort\":\"([A-Za-z_-]+)\"")

    public init(home: String = Paths.home, procs: ProcessInspecting, hookDir: String = Paths.codexHookStateDir,
                windowProbe: WindowProbe? = nil) {
        self.home = home
        self.procs = procs
        self.hookDir = hookDir
        self.windowTitles = windowProbe.map { probe in { probe.titles(for: $0) } }
        self.refreshTitles = windowProbe.map { probe in { probe.refresh() } }
    }

    final class Rollout {
        let tail: LineTail
        var state: SessionState = .ready
        var stateTs = 0.0
        var turnStart: Double?
        var active = 0.0
        var tin = 0, tout = 0, ctx = 0, ctxmax = 0
        var model: String?
        var effort: String?
        var firstUser: String?

        init(path: String) { tail = LineTail(path: path) }

        func reset() {
            state = .ready; stateTs = 0; turnStart = nil; active = 0
            tin = 0; tout = 0; ctx = 0; ctxmax = 0
            model = nil; effort = nil; firstUser = nil
        }

        private static let eventNeedle = Data("\"event_msg\"".utf8)
        private static let contextNeedle = Data("\"turn_context\"".utf8)
        private static let effortNeedle = Data("effort\":\"".utf8)

        func update() {
            tail.read(onReset: reset) { line in
                if JSON.contains(line, Self.effortNeedle) {
                    let s = String(decoding: line, as: UTF8.self)
                    if let m = CodexProvider.effortPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                       let r = Range(m.range(at: 1), in: s) {
                        effort = String(s[r])
                    }
                }
                let isEvent = JSON.contains(line, Self.eventNeedle)
                guard isEvent || JSON.contains(line, Self.contextNeedle), let obj = JSON.object(line) else { return }
                ingest(obj)
            }
        }

        func ingest(_ obj: [String: Any]) {
            let ts = Time.parse(obj["timestamp"] as? String) ?? 0
            guard let payload = obj["payload"] as? [String: Any] else { return }
            if obj["type"] as? String == "turn_context" {
                if let m = JSON.string(payload["model"]) { model = m }
                return
            }
            switch payload["type"] as? String {
            case "task_started":
                state = .working
                stateTs = ts
                turnStart = ts
                if JSON.int(payload["model_context_window"]) > 0 { ctxmax = JSON.int(payload["model_context_window"]) }
            case "task_complete", "turn_aborted":
                state = .done
                stateTs = ts
                if let start = turnStart { active += Swift.max(0, ts - start) }
                turnStart = nil
            case "token_count":
                guard let info = payload["info"] as? [String: Any] else { return }
                if let total = info["total_token_usage"] as? [String: Any] {
                    tin = JSON.int(total["input_tokens"])
                    tout = JSON.int(total["output_tokens"])
                }
                if let last = info["last_token_usage"] as? [String: Any] { ctx = JSON.int(last["total_tokens"]) }
                if JSON.int(info["model_context_window"]) > 0 { ctxmax = JSON.int(info["model_context_window"]) }
            case "user_message":
                if firstUser == nil { firstUser = JSON.string(payload["message"]) }
            case "thread_settings_applied":
                if let m = JSON.string((payload["thread_settings"] as? [String: Any])?["model"]) { model = m }
            default:
                break
            }
        }
    }

    public func sessions(now: Double) -> [Session] {
        let candidates = discover()
        guard !candidates.isEmpty else {
            rollouts.removeAll()
            return []
        }
        refreshTitles?()
        let defaults = config.get((home as NSString).appendingPathComponent(".codex/config.toml"))
        let names = index.get((home as NSString).appendingPathComponent(".codex/session_index.jsonl")) ?? [:]
        // 1. Exact: the rollout a process (or its app-server child) holds open names its thread.
        var assigned: [Int32: SQLiteReader.Row] = [:]
        var claimed = Set<String>()
        let children = childMap()
        for info in candidates {
            for id in openThreadIds(info.pid, children: children) where !claimed.contains(id) {
                guard let row = threadRows(where: "id = ?", [id]).first else { continue }
                assigned[info.pid] = row
                claimed.insert(id)
                break
            }
        }
        // 2. Fallback (GUIDE §4.2): threads in the same cwd updated since the process started. Newest processes
        //    pick first, preferring threads created after they started, so an older session can't take a newer one's thread.
        var cwds: [Int32: String] = [:]
        for info in candidates.reversed() {
            let cwd = procs.cwd(info.pid) ?? ""
            cwds[info.pid] = cwd
            guard assigned[info.pid] == nil else { continue }
            let since = info.started - 5
            let rows = threadRows(where: "cwd = ? AND updated_at >= ?", [cwd, Int(since)]).filter { !claimed.contains($0["id"] ?? "") }
            let own = rows.first { (Double($0["created_at"] ?? "") ?? 0) >= since }
            if let row = own ?? rows.first, let id = row["id"] {
                assigned[info.pid] = row
                claimed.insert(id)
            }
        }
        let result = candidates.map { info in
            session(info: info, cwd: cwds[info.pid] ?? "", thread: assigned[info.pid], names: names, defaults: defaults, now: now)
        }
        let live = Set(candidates.map(\.pid))
        rollouts = rollouts.filter { live.contains($0.key) }
        return result
    }

    /// Interactive `codex` processes on a terminal, oldest first.
    func discover() -> [ProcInfo] {
        var found: [ProcInfo] = []
        for pid in procs.allPids() {
            guard let info = procs.info(pid), Self.isCodexName(info.name), info.hasTTY else { continue }
            if let parent = procs.info(info.ppid), Self.isCodexName(parent.name) { continue }
            if procs.arguments(pid).dropFirst().contains(where: Self.excludedSubcommands.contains) { continue }
            found.append(info)
        }
        return found.sorted { ($0.started, $0.pid) < ($1.started, $1.pid) }
    }

    static func isCodexName(_ name: String) -> Bool {
        name == "codex" || (name.hasPrefix("codex-") && name != CodexHooks.helperName)
    }

    /// pid → child pids, from one pass over the process table.
    private func childMap() -> [Int32: [Int32]] {
        var map: [Int32: [Int32]] = [:]
        for pid in procs.allPids() {
            if let info = procs.info(pid) { map[info.ppid, default: []].append(pid) }
        }
        return map
    }

    /// Thread ids of rollout files held open by `pid` or its descendants (newer Codex records from an app-server child).
    private func openThreadIds(_ pid: Int32, children: [Int32: [Int32]]) -> [String] {
        var ids: [String] = []
        var queue = [pid]
        var visited = Set<Int32>()
        while let current = queue.popLast(), visited.count < 32 {
            guard visited.insert(current).inserted else { continue }
            for path in procs.openFiles(current) {
                let name = (path as NSString).lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), path.contains("/sessions/") else { continue }
                let stem = name.dropLast(".jsonl".count)
                if stem.count > 36 { ids.append(String(stem.suffix(36))) }
            }
            queue.append(contentsOf: children[current] ?? [])
        }
        return ids
    }

    /// Interactive, non-archived top-level threads matching `condition`, most recently updated first.
    private func threadRows(where condition: String, _ params: [Any]) -> [SQLiteReader.Row] {
        let db = (home as NSString).appendingPathComponent(".codex/state_5.sqlite")
        if columns == nil { columns = SQLiteReader.columns(db, table: "threads") }
        guard let cols = columns, cols.contains("id"), cols.contains("rollout_path") else {
            columns = nil
            return []
        }
        let wanted = ["id", "rollout_path", "title", "first_user_message", "model", "reasoning_effort", "created_at", "updated_at"]
        var sql = "SELECT \(wanted.filter(cols.contains).joined(separator: ", ")) FROM threads WHERE \(condition)"
        if cols.contains("archived") { sql += " AND archived = 0" }
        if cols.contains("agent_role") { sql += " AND (agent_role IS NULL OR agent_role = '')" }
        if cols.contains("source") { sql += " AND source = 'cli'" }
        sql += " ORDER BY updated_at DESC LIMIT 16"
        guard let rows = SQLiteReader.query(db, sql, params) else {
            columns = nil
            return []
        }
        return rows
    }

    private func session(info: ProcInfo, cwd: String, thread: SQLiteReader.Row?, names: [String: String],
                         defaults: (model: String?, effort: String?)?, now: Double) -> Session {
        var r: Rollout?
        if let path = thread?["rollout_path"], !path.isEmpty {
            if rollouts[info.pid]?.tail.path != path { rollouts[info.pid] = Rollout(path: path) }
            r = rollouts[info.pid]
            r?.update()
        } else {
            rollouts[info.pid] = nil
        }

        var state = r?.state ?? .ready
        var since = (r?.stateTs ?? 0) > 0 ? r!.stateTs : info.started
        var waiting = ""
        if let id = thread?["id"], let hook = CodexHooks.read(threadId: id, dir: hookDir),
           hook.ts >= (r?.stateTs ?? 0) - 1,
           hook.ts >= info.started - 1, // older records belong to an earlier run of the thread
           let hookState = CodexHooks.state(of: hook) {
            if hookState != state { since = hook.ts }
            state = hookState
            waiting = CodexHooks.waiting(for: hook)
        }

        let threadName = thread.flatMap { names[$0["id"] ?? ""] }
        let title = threadName
            ?? thread?["title"].flatMap { $0.isEmpty ? nil : Format.firstLine($0) }
            ?? (thread?["first_user_message"]).flatMap { $0.isEmpty ? nil : Format.firstLine($0) }
            ?? r?.firstUser.map { Format.firstLine($0) }
            ?? ""

        if state != .input, let titles = windowTitles?(info.pid) {
            let proj = Format.project(cwd, home: home)
            let hit = titles.contains { t in
                let range = NSRange(t.startIndex..., in: t)
                guard Self.attentionTitle.firstMatch(in: t, range: range) != nil else { return false }
                return titles.count == 1 || t.contains(proj) || (!title.isEmpty && t.contains(title))
            }
            if hit {
                state = .input
                waiting = ""
            }
        }

        var active = r?.active ?? 0
        if let start = r?.turnStart, state == .working || state == .input { active += Swift.max(0, now - start) }
        let model = r?.model ?? thread?["model"].flatMap { $0.isEmpty ? nil : $0 } ?? defaults?.model ?? ""
        let effort = r?.effort ?? thread?["reasoning_effort"].flatMap { $0.isEmpty ? nil : $0 } ?? defaults?.effort ?? ""
        return Session(
            kind: .codex, pid: info.pid, cwd: cwd, title: title, model: model, effort: effort,
            state: state, waiting: waiting, since: since, started: info.started, active: active,
            ctx: r?.ctx ?? 0, ctxmax: (r?.ctxmax ?? 0) > 0 ? r!.ctxmax : ContextWindow.codex,
            tin: r?.tin ?? 0, tout: r?.tout ?? 0
        )
    }

    /// Top-level `model` and `model_reasoning_effort` from config.toml.
    static func parseConfig(_ path: String) -> (model: String?, effort: String?)? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var model: String?
        var effort: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            var value = parts[1]
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if parts[0] == "model" { model = value }
            if parts[0] == "model_reasoning_effort" { effort = value }
        }
        return (model, effort)
    }

    static func parseIndex(_ path: String) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let obj = JSON.object(Data(line)), let id = JSON.string(obj["id"]),
                  let name = JSON.string(obj["thread_name"]) else { continue }
            names[id] = name
        }
        return names
    }
}
