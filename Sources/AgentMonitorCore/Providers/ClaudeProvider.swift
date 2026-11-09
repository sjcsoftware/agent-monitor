import Foundation

/// Claude Code: `~/.claude/sessions/<pid>.json` + the session's JSONL transcript (GUIDE §4.1).
public final class ClaudeProvider: AgentProvider {
    public let kind = AgentKind.claude
    private let home: String
    private let procs: ProcessInspecting
    private var transcripts: [Int32: Transcript] = [:]
    private var located: [String: String] = [:] // sessionId → transcript path (fallback search)
    private let sessionFiles = FileCache<[String: Any]> { JSON.object(file: $0) }
    private let settings = FileCache<[String: Any]> { JSON.object(file: $0) }

    public init(home: String = Paths.home, procs: ProcessInspecting) {
        self.home = home
        self.procs = procs
    }

    final class Transcript {
        let tail: LineTail
        var usage: [String: (input: Int, output: Int)] = [:]
        var lastMessageId: String?
        var tin = 0, tout = 0, ctx = 0
        var model: String?
        var effort: String?
        var largeContext = false
        var aiTitle: String?
        var customTitle: String?
        var firstPrompt: String?
        var turns = 0
        var activeMs = 0.0

        init(path: String) { tail = LineTail(path: path) }

        func reset() {
            usage = [:]; lastMessageId = nil
            tin = 0; tout = 0; ctx = 0
            model = nil; effort = nil; largeContext = false
            aiTitle = nil; customTitle = nil; firstPrompt = nil
            turns = 0; activeMs = 0
        }

        private static let needles = ["\"assistant\"", "api-request", "ai-title", "custom-title", "last-prompt", "turn_duration"]
            .map { Data($0.utf8) }

        func update() {
            tail.read(onReset: reset) { line in
                guard Self.needles.contains(where: { JSON.contains(line, $0) }), let obj = JSON.object(line) else { return }
                ingest(obj)
            }
        }

        func ingest(_ obj: [String: Any]) {
            switch obj["type"] as? String {
            case "assistant":
                guard obj["isSidechain"] as? Bool != true,
                      let message = obj["message"] as? [String: Any],
                      let u = message["usage"] as? [String: Any] else { return }
                let input = JSON.int(u["input_tokens"]) + JSON.int(u["cache_read_input_tokens"]) + JSON.int(u["cache_creation_input_tokens"])
                let output = JSON.int(u["output_tokens"])
                let id = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
                if let old = usage[id] {
                    tin -= old.input; tout -= old.output
                }
                usage[id] = (input, output)
                tin += input; tout += output
                lastMessageId = id
                ctx = input + output
                if let m = JSON.string(message["model"]), m != "<synthetic>" { model = m }
            case "api-request":
                guard let params = obj["params"] as? [String: Any] else { return }
                if let e = JSON.string((params["output_config"] as? [String: Any])?["effort"]) { effort = e }
                if let betas = params["betas"] as? [String], betas.contains(where: { $0.hasPrefix("context-1m") }) {
                    largeContext = true
                }
            case "ai-title":
                if let t = JSON.string(obj["aiTitle"]) ?? JSON.string(obj["title"]) { aiTitle = t }
            case "custom-title":
                if let t = JSON.string(obj["customTitle"]) ?? JSON.string(obj["title"]) { customTitle = t }
            case "last-prompt":
                if firstPrompt == nil, let p = JSON.string(obj["lastPrompt"]) { firstPrompt = p }
            case "system":
                guard obj["subtype"] as? String == "turn_duration", obj["isSidechain"] as? Bool != true else { return }
                activeMs += JSON.double(obj["durationMs"]) ?? 0
                turns += 1
            default:
                break
            }
        }
    }

    public func sessions(now: Double) -> [Session] {
        let dir = (home as NSString).appendingPathComponent(".claude/sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            transcripts.removeAll()
            return []
        }
        var result: [Session] = []
        var livePids = Set<Int32>()
        var liveFiles = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            liveFiles.insert(path)
            guard let file = sessionFiles.get(path) else { continue }
            let filePid = JSON.int(file["pid"])
            let pid = Int32(truncatingIfNeeded: filePid != 0 ? filePid : Int(name.dropLast(5)) ?? 0)
            guard pid > 0,
                  (file["kind"] as? String ?? "interactive") == "interactive",
                  let info = procs.info(pid), info.hasTTY, info.isForeground,
                  procs.looksLike(pid, tool: "claude")
            else { continue }
            livePids.insert(pid)
            result.append(session(pid: pid, file: file, info: info, now: now))
        }
        sessionFiles.retain(liveFiles)
        transcripts = transcripts.filter { livePids.contains($0.key) }
        return result
    }

    private func session(pid: Int32, file: [String: Any], info: ProcInfo, now: Double) -> Session {
        let cwd = JSON.string(file["cwd"]) ?? procs.cwd(pid) ?? ""
        let sessionId = JSON.string(file["sessionId"]) ?? ""
        var t: Transcript?
        if let path = transcriptPath(sessionId: sessionId, cwd: cwd) {
            if transcripts[pid]?.tail.path != path { transcripts[pid] = Transcript(path: path) }
            t = transcripts[pid]
            t?.update()
        } else {
            transcripts[pid] = nil
        }

        let ranTurn = (t?.turns ?? 0) > 0 || !(t?.usage.isEmpty ?? true)
        let status = (file["status"] as? String ?? "").lowercased()
        let state: SessionState
        switch status {
        case "waiting": state = .input
        case "busy", "shell": state = .working
        default: state = ranTurn ? .done : .ready
        }
        let waiting = state == .input ? Self.waitingKind(file["waitingFor"]) : ""
        let started = Time.epoch(file["startedAt"]) ?? info.started
        let since = Time.epoch(file["statusUpdatedAt"]) ?? started

        let model = t?.model ?? (settingsValue()?["model"] as? String) ?? ""
        let effort = t?.effort ?? defaultEffort(model: model) ?? ""
        let ctx = t?.ctx ?? 0
        let large = (t?.largeContext ?? false) || model.lowercased().contains("[1m]") || ctx > ContextWindow.claude
        var active = (t?.activeMs ?? 0) / 1000
        if state == .working { active += Swift.max(0, now - since) }

        let title = t?.customTitle ?? t?.aiTitle ?? t?.firstPrompt.map { Format.firstLine($0) } ?? ""
        return Session(
            kind: .claude, pid: pid, cwd: cwd, title: title, model: model, effort: effort,
            state: state, waiting: waiting, since: since, started: started, active: active,
            ctx: ctx, ctxmax: large ? ContextWindow.claudeLarge : ContextWindow.claude,
            tin: t?.tin ?? 0, tout: t?.tout ?? 0
        )
    }

    static func waitingKind(_ value: Any?) -> String {
        let text: String
        if let s = value as? String { text = s }
        else if let d = value as? [String: Any] { text = (d["type"] as? String) ?? (d["kind"] as? String) ?? "" }
        else { text = "" }
        let lower = text.lowercased()
        if lower.contains("perm") || lower.contains("approv") || lower.contains("tool") { return "permission" }
        if lower.isEmpty { return "" }
        return "question"
    }

    /// `~/.claude/projects/<cwd with non-alphanumerics → '-'>/<sessionId>.jsonl`, else a search.
    private func transcriptPath(sessionId: String, cwd: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let projects = (home as NSString).appendingPathComponent(".claude/projects")
        let slug = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        let direct = "\(projects)/\(slug)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: direct) { return direct }
        if let hit = located[sessionId], FileManager.default.fileExists(atPath: hit) { return hit }
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for d in dirs {
            let candidate = "\(projects)/\(d)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) {
                located[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func settingsValue() -> [String: Any]? {
        settings.get((home as NSString).appendingPathComponent(".claude/settings.json"))
    }

    private func defaultEffort(model: String) -> String? {
        guard let s = settingsValue() else { return nil }
        if let perModel = (s["modelSettings"] as? [String: Any])?[model] as? [String: Any],
           let e = JSON.string(perModel["effortLevel"]) {
            return e
        }
        return JSON.string(s["effortLevel"])
    }
}
