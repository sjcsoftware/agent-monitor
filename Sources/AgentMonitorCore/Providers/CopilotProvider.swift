import Foundation

/// GitHub Copilot CLI: `~/.copilot/session-state/<id>/inuse.<pid>.lock` + `events.jsonl` (GUIDE §4.3).
public final class CopilotProvider: AgentProvider {
    public let kind = AgentKind.copilot
    private let home: String
    private let procs: ProcessInspecting
    private var logs: [Int32: EventLog] = [:]
    private var dirLocks: [String: (mtime: Double, pids: [Int32])] = [:]
    private let workspaces = FileCache<[String: String]> { CopilotProvider.parseWorkspace($0) }
    private let settings = FileCache<[String: Any]> { CopilotProvider.parseSettings($0) }

    static let questionTools: Set<String> = ["ask_user", "exit_plan_mode"]
    static let turnEndGrace = 2.0

    public init(home: String = Paths.home, procs: ProcessInspecting) {
        self.home = home
        self.procs = procs
    }

    final class EventLog {
        let tail: LineTail
        var busy = false
        var everPrompted = false
        var interactionStart = 0.0
        var turnRunning = false
        var turnStart = 0.0
        var lastTurnEnd = 0.0
        var idleSince = 0.0
        var active = 0.0
        var pendingPermissions: [String: Double] = [:]
        var pendingQuestions: [String: Double] = [:]
        var tin = 0, tout = 0, ctx = 0, ctxmax = 0
        var model: String?
        var effort: String?
        var firstPrompt: String?

        init(path: String) { tail = LineTail(path: path) }

        func reset() {
            busy = false; everPrompted = false; interactionStart = 0
            turnRunning = false; turnStart = 0; lastTurnEnd = 0; idleSince = 0; active = 0
            pendingPermissions = [:]; pendingQuestions = [:]
            tin = 0; tout = 0; ctx = 0; ctxmax = 0
            model = nil; effort = nil; firstPrompt = nil
        }

        private static let wanted: Set<String> = [
            "session.start", "user.message", "assistant.turn_start", "assistant.turn_end", "abort", "session.shutdown",
            "permission.requested", "permission.completed", "tool.execution_start", "tool.execution_complete",
            "session.usage_record", "session.model_change", "session.compaction_complete",
        ]

        private static let turnEvents: Set<String> = ["user.message", "assistant.turn_start", "assistant.turn_end"]

        func update() {
            tail.read(onReset: reset) { line in
                guard let type = JSON.scanString(line, key: "type"), Self.wanted.contains(type) else { return }
                if type == "tool.execution_complete" {
                    // Results can be huge; only the call id matters, and only while a question is pending.
                    guard !pendingQuestions.isEmpty, let id = JSON.scanString(line, key: "toolCallId") else { return }
                    pendingQuestions[id] = nil
                    return
                }
                guard let obj = JSON.object(line) else { return }
                let data = obj["data"] as? [String: Any] ?? [:]
                // Sub-agents log their own turns and prompts into the parent's file; they don't change its state.
                let fromSubagent = obj["agentId"] != nil || data["parentToolCallId"] != nil
                if fromSubagent && Self.turnEvents.contains(type) { return }
                ingest(type: type, data: data, ts: Time.parse(obj["timestamp"] as? String) ?? 0)
            }
        }

        private var interactionOver: Bool {
            lastTurnEnd > interactionStart && !turnRunning
        }

        func ingest(type: String, data: [String: Any], ts: Double) {
            switch type {
            case "session.start":
                model = JSON.string(data["selectedModel"]) ?? model
                effort = JSON.string(data["reasoningEffort"]) ?? effort
            case "user.message":
                busy = true
                everPrompted = true
                interactionStart = ts
                if firstPrompt == nil { firstPrompt = JSON.string(data["content"]) }
            case "assistant.turn_start":
                if !busy || (interactionOver && ts - lastTurnEnd > CopilotProvider.turnEndGrace) { interactionStart = ts }
                busy = true
                everPrompted = true
                turnRunning = true
                turnStart = ts
            case "assistant.turn_end":
                if turnRunning { active += Swift.max(0, ts - turnStart) }
                turnRunning = false
                lastTurnEnd = ts
                idleSince = ts
            case "abort", "session.shutdown":
                if turnRunning { active += Swift.max(0, ts - turnStart) }
                busy = false
                turnRunning = false
                idleSince = ts
                pendingPermissions = [:]
                pendingQuestions = [:]
            case "permission.requested":
                if let id = JSON.string(data["requestId"]) { pendingPermissions[id] = ts }
            case "permission.completed":
                if let id = JSON.string(data["requestId"]) { pendingPermissions[id] = nil }
            case "tool.execution_start":
                if let name = JSON.string(data["toolName"]), CopilotProvider.questionTools.contains(name),
                   let id = JSON.string(data["toolCallId"]) {
                    pendingQuestions[id] = ts
                }
            case "session.usage_record":
                let usage = data["usage"] as? [String: Any] ?? data
                let input = JSON.int(usage["inputTokens"])
                let output = JSON.int(usage["outputTokens"])
                tin += input
                tout += output
                let initiator = (usage["initiator"] as? String) ?? (data["initiator"] as? String) ?? ""
                let nested = usage["parentToolCallId"] != nil || data["parentToolCallId"] != nil
                if (initiator == "user" || initiator == "agent") && !nested {
                    ctx = input + output
                    if JSON.int(usage["maxPromptTokens"]) > 0 { ctxmax = JSON.int(usage["maxPromptTokens"]) }
                    if let m = JSON.string(usage["model"]) { model = m }
                }
            case "session.model_change":
                model = JSON.string(data["newModel"]) ?? model
                effort = JSON.string(data["reasoningEffort"]) ?? effort
            case "session.compaction_complete":
                if data["postCompactionTokens"] != nil { ctx = JSON.int(data["postCompactionTokens"]) }
            default:
                break
            }
        }

        /// (state, since, waiting) at `now`.
        func state(now: Double, started: Double) -> (SessionState, Double, String) {
            let pending = Array(pendingPermissions.values) + Array(pendingQuestions.values)
            if let oldest = pending.min() {
                return (.input, oldest, pendingPermissions.isEmpty ? "question" : "permission")
            }
            if busy {
                if interactionOver && now - lastTurnEnd > CopilotProvider.turnEndGrace {
                    return (.done, lastTurnEnd, "")
                }
                return (.working, interactionStart, "")
            }
            if everPrompted { return (.done, idleSince > 0 ? idleSince : started, "") }
            return (.ready, started, "")
        }
    }

    public func sessions(now: Double) -> [Session] {
        let root = (home as NSString).appendingPathComponent(".copilot/session-state")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            logs.removeAll()
            return []
        }
        // pid → session directories holding its lock; dirs are re-listed only when their mtime changes.
        var byPid: [Int32: [String]] = [:]
        var seen = Set<String>()
        for name in dirs where !name.hasPrefix(".") {
            let dir = (root as NSString).appendingPathComponent(name)
            guard let mtime = fileMTime(dir) else { continue }
            seen.insert(dir)
            if dirLocks[dir]?.mtime != mtime {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                dirLocks[dir] = (mtime, files.compactMap(Self.lockPid))
            }
            for pid in dirLocks[dir]?.pids ?? [] { byPid[pid, default: []].append(dir) }
        }
        dirLocks = dirLocks.filter { seen.contains($0.key) }

        var result: [Session] = []
        for (pid, candidates) in byPid {
            guard let info = procs.info(pid), info.hasTTY, procs.looksLike(pid, tool: "copilot") else { continue }
            let args = procs.arguments(pid).dropFirst()
            if args.contains(where: { $0 == "-p" || $0 == "--prompt" || $0.hasPrefix("--prompt=") || $0 == "--acp" }) { continue }
            let dir = candidates.max { (fileMTime("\($0)/events.jsonl") ?? 0) < (fileMTime("\($1)/events.jsonl") ?? 0) }!
            result.append(session(pid: pid, info: info, dir: dir, now: now))
        }
        logs = logs.filter { byPid[$0.key] != nil }
        workspaces.retain(Set(byPid.values.flatMap { $0.map { "\($0)/workspace.yaml" } }))
        return result
    }

    private func session(pid: Int32, info: ProcInfo, dir: String, now: Double) -> Session {
        let path = "\(dir)/events.jsonl"
        if logs[pid]?.tail.path != path { logs[pid] = EventLog(path: path) }
        let log = logs[pid]!
        log.update()

        let (state, since, waiting) = log.state(now: now, started: info.started)
        let ws = workspaces.get("\(dir)/workspace.yaml") ?? [:]
        let defaults = settings.get((home as NSString).appendingPathComponent(".copilot/settings.json"))
        let title = ws["name"] ?? ws["summary"] ?? log.firstPrompt.map { Format.firstLine($0) } ?? ""
        let cwd = ws["cwd"] ?? procs.cwd(pid) ?? ""
        var active = log.active
        if log.turnRunning { active += Swift.max(0, now - log.turnStart) }
        return Session(
            kind: .copilot, pid: pid, cwd: cwd, title: title,
            model: log.model ?? JSON.string(defaults?["model"]) ?? "",
            effort: log.effort ?? JSON.string(defaults?["effortLevel"]) ?? "",
            state: state, waiting: waiting, since: since, started: info.started, active: active,
            ctx: log.ctx, ctxmax: log.ctxmax > 0 ? log.ctxmax : ContextWindow.copilot,
            tin: log.tin, tout: log.tout
        )
    }

    /// `inuse.<pid>.lock` → pid.
    static func lockPid(_ name: String) -> Int32? {
        guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
        return Int32(name.dropFirst(6).dropLast(5))
    }

    /// Flat `key: value` pairs from workspace.yaml (enough for name/summary/cwd).
    static func parseWorkspace(_ path: String) -> [String: String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
                if f == "\"" { value = value.replacingOccurrences(of: "\\\"", with: "\"") }
            }
            if !value.isEmpty, value != "|", value != ">" { out[key] = value }
        }
        return out
    }

    /// settings.json may contain `//` comment lines.
    static func parseSettings(_ path: String) -> [String: Any]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return JSON.object(Data(cleaned.utf8))
    }
}
