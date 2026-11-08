import Foundation
import SQLite3
import Testing
@testable import AgentMonitorCore

// MARK: - Fixtures

final class FakeProcs: ProcessInspecting {
    struct Proc { var info: ProcInfo; var args: [String]; var path: String?; var cwd: String?; var files: [String] = [] }
    var table: [Int32: Proc] = [:]

    func add(_ pid: Int32, name: String, ppid: Int32 = 1, tty: Bool = true, started: Double = 1000,
             args: [String]? = nil, path: String? = nil, cwd: String? = nil, files: [String] = []) {
        table[pid] = Proc(info: ProcInfo(pid: pid, ppid: ppid, name: name, hasTTY: tty, started: started),
                          args: args ?? [name], path: path, cwd: cwd, files: files)
    }

    func allPids() -> [Int32] { Array(table.keys) }
    func info(_ pid: Int32) -> ProcInfo? { table[pid]?.info }
    func arguments(_ pid: Int32) -> [String] { table[pid]?.args ?? [] }
    func environment(_ pid: Int32) -> [String: String] { [:] }
    func executablePath(_ pid: Int32) -> String? { table[pid]?.path }
    func cwd(_ pid: Int32) -> String? { table[pid]?.cwd }
    func openFiles(_ pid: Int32) -> [String] { table[pid]?.files ?? [] }
}

final class TempDir {
    let path: String

    init() {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("am-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func write(_ rel: String, _ text: String) -> String {
        let full = (path as NSString).appendingPathComponent(rel)
        try? FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: full, atomically: false, encoding: .utf8)
        return full
    }

    func append(_ rel: String, _ text: String) {
        let full = (path as NSString).appendingPathComponent(rel)
        guard let h = FileHandle(forWritingAtPath: full) else { write(rel, text); return }
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    }
}

func jsonl(_ objects: [[String: Any]]) -> String {
    objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n" }.joined()
}

// MARK: - Formatting

struct FormatTests {
    @Test func tokens() {
        #expect(Format.tokens(0) == "0")
        #expect(Format.tokens(999) == "999")
        #expect(Format.tokens(1000) == "1k")
        #expect(Format.tokens(1234) == "1.2k")
        #expect(Format.tokens(9_999) == "10k")
        #expect(Format.tokens(84_321) == "84k")
        #expect(Format.tokens(999_999) == "1M")
        #expect(Format.tokens(1_500_000) == "1.5M")
        #expect(Format.tokens(120_400_000) == "120M")
    }

    @Test func durations() {
        #expect(Format.duration(42) == "42s")
        #expect(Format.duration(17 * 60 + 5) == "17m")
        #expect(Format.duration(2 * 3600 + 5 * 60) == "2h 05m")
        #expect(Format.duration(-3) == "0s")
    }

    @Test func modelNames() {
        #expect(Format.model("claude-opus-4-6-20260101") == "opus 4.6")
        #expect(Format.model("claude-opus-5-5[1m]") == "opus 5.5")
        #expect(Format.model("claude-3-5-sonnet-20241022") == "sonnet 3.5")
        #expect(Format.model("claude-opus-5.5") == "opus 5.5")
        #expect(Format.model("gpt-6.1-sol") == "gpt-6.1-sol")
    }

    @Test func projectsAndLevels() {
        #expect(Format.project("/Users/me", home: "/Users/me") == "~")
        #expect(Format.project("/Users/me/code/app/", home: "/Users/me") == "app")
        #expect(Format.contextLevel(49) == "lo")
        #expect(Format.contextLevel(50) == "mid")
        #expect(Format.contextLevel(80) == "hi")
    }

    @Test func cardModel() {
        let s = Session(kind: .claude, pid: 7, cwd: "/x/proj", model: "claude-opus-4-6", state: .input, waiting: "permission",
                        since: 880, started: 0, active: 500, ctx: 84_000, ctxmax: 200_000, tin: 1_400_000, tout: 12_000)
        let c = CardModel(session: s, now: 1000, home: "/home")
        #expect(c.title == "new session")
        #expect(c.statetext == "needs you · permission")
        #expect(c.since == "2m")
        #expect(c.contextText == "84k / 200k · 42%")
        #expect(c.tin == "1.4M" && c.tout == "12k")
        #expect(c.actpct == 50)
    }
}

// MARK: - Incremental reads

struct LineTailTests {
    @Test func partialLinesAndTruncation() {
        let dir = TempDir()
        let path = dir.write("log.jsonl", "one\ntw")
        let tail = LineTail(path: path)
        var lines: [String] = []
        tail.read { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["one"])
        dir.append("log.jsonl", "o\nthree\n")
        tail.read { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["one", "two", "three"])

        dir.write("log.jsonl", "new\n") // shrank → reset and re-read
        var resets = 0
        lines = []
        tail.read(onReset: { resets += 1 }) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(resets == 1)
        #expect(lines == ["new"])
    }

    @Test func corruptedNumbersDontTrap() {
        #expect(Format.duration(-1e300) == "0s")
        #expect(Format.duration(.infinity) == "0s")
        #expect(JSON.int(1e30) == 1_000_000_000_000)
        #expect(JSON.double(Double.nan) == nil)
        let s = Session(kind: .codex, pid: 1, since: 1e15, started: -1e15, active: 1e15, ctx: Int.max / 2, ctxmax: 1)
        let c = CardModel(session: s, now: 0)
        #expect(c.ctxpct == 100 && c.actpct <= 100)
    }

    @Test func openFilesSeesOwnHandles() throws {
        let dir = TempDir()
        defer { withExtendedLifetime(dir) {} }
        let path = dir.write("held.jsonl", "x")
        let handle = try #require(FileHandle(forReadingAtPath: path))
        defer { try? handle.close() }
        let open = SystemProcesses().openFiles(getpid()).map { ($0 as NSString).lastPathComponent }
        #expect(open.contains("held.jsonl"))
    }

    @Test func ancestryWalksThroughRootOwnedProcesses() throws {
        // Terminals start shells via root's /usr/bin/login; the walk to the terminal app must not stop there.
        let procs = SystemProcesses()
        let launchd = try #require(procs.info(1))
        #expect(launchd.name == "launchd")
        var current = getpid()
        for _ in 0..<64 {
            let info = try #require(procs.info(current), "lost the chain at pid \(current)")
            if info.ppid <= 1 { return }
            current = info.ppid
        }
        Issue.record("ancestry did not reach launchd")
    }

    @Test func isoTimestamps() {
        #expect(Time.parse("2026-11-08T15:11:18.500Z") == 1_794_150_678.5)
        #expect(Time.parse("2026-11-08T16:11:18+01:00") == 1_794_150_678)
        #expect(Time.epoch(1_794_150_678_500) == 1_794_150_678.5)
    }
}

// MARK: - Claude

struct ClaudeProviderTests {
    func setup(status: String, lines: [[String: Any]]) -> (TempDir, ClaudeProvider) {
        let home = TempDir()
        home.write(".claude/sessions/42.json", """
        {"pid":42,"sessionId":"s1","cwd":"/work/my.app","kind":"interactive","status":"\(status)",
         "statusUpdatedAt":1700000000000,"startedAt":1699999000000,"waitingFor":"permission prompt"}
        """)
        home.write(".claude/sessions/43.json", #"{"pid":43,"sessionId":"s2","cwd":"/w","kind":"print","status":"busy"}"#)
        home.write(".claude/projects/-work-my-app/s1.jsonl", jsonl(lines))
        home.write(".claude/settings.json", #"{"effortLevel":"medium","modelSettings":{"claude-opus-4-6":{"effortLevel":"high"}}}"#)
        let procs = FakeProcs()
        procs.add(42, name: "2.1.319", path: "/Users/x/.local/share/claude/versions/2.1.319")
        procs.add(43, name: "claude")
        return (home, ClaudeProvider(home: home.path, procs: procs))
    }

    static let transcript: [[String: Any]] = [
        ["type": "last-prompt", "lastPrompt": "Fix the login bug\nplease"],
        ["type": "assistant", "message": ["id": "m1", "model": "claude-opus-4-6",
                                           "usage": ["input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 90, "output_tokens": 5]]],
        // Same message id repeated per content block: counted once.
        ["type": "assistant", "message": ["id": "m1", "model": "claude-opus-4-6",
                                           "usage": ["input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 90, "output_tokens": 50]]],
        ["type": "assistant", "isSidechain": true, "message": ["id": "side", "usage": ["input_tokens": 999_999, "output_tokens": 1]]],
        ["type": "system", "subtype": "turn_duration", "durationMs": 30_000],
        ["type": "ai-title", "aiTitle": "Login bug fix"],
    ]

    @Test func readsSessionAndTranscript() throws {
        let (home, provider) = setup(status: "idle", lines: Self.transcript)
        defer { withExtendedLifetime(home) {} }
        let sessions = provider.sessions(now: 1_700_000_100)
        #expect(sessions.count == 1) // print-mode session 43 is skipped
        let s = try #require(sessions.first)
        #expect(s.id == "claude-42")
        #expect(s.state == .done)
        #expect(s.title == "Login bug fix")
        #expect(s.model == "claude-opus-4-6")
        #expect(s.effort == "high") // per-model default from settings
        #expect(s.tin == 1100 && s.tout == 50)
        #expect(s.ctx == 1150)
        #expect(s.ctxmax == 200_000)
        #expect(s.active == 30)
        #expect(s.started == 1_699_999_000)
    }

    @Test func stateMappingAndIncrementalUpdates() throws {
        let (home, provider) = setup(status: "waiting", lines: [])
        defer { withExtendedLifetime(home) {} }
        var s = try #require(provider.sessions(now: 1_700_000_100).first)
        #expect(s.state == .input)
        #expect(s.waiting == "permission")
        #expect(s.since == 1_700_000_000)
        #expect(s.title == "")

        home.write(".claude/sessions/42.json", #"{"pid":42,"sessionId":"s1","cwd":"/work/my.app","status":"busy"}"#)
        home.append(".claude/projects/-work-my-app/s1.jsonl", jsonl([
            ["type": "custom-title", "customTitle": "Named"],
            ["type": "api-request", "params": ["output_config": ["effort": "max"], "betas": ["context-1m-2025-08-07"]]],
        ]))
        s = try #require(provider.sessions(now: 1_700_000_100).first)
        #expect(s.state == .working)
        #expect(s.title == "Named")
        #expect(s.effort == "max")
        #expect(s.ctxmax == 1_000_000)
    }

    @Test func ignoresDeadOrForeignProcesses() {
        let home = TempDir()
        defer { withExtendedLifetime(home) {} }
        home.write(".claude/sessions/42.json", #"{"pid":42,"sessionId":"s1","cwd":"/w","kind":"interactive"}"#)
        let procs = FakeProcs()
        procs.add(42, name: "python3", path: "/usr/bin/python3") // pid reused by something else
        #expect(ClaudeProvider(home: home.path, procs: procs).sessions(now: 0).isEmpty)
        procs.add(42, name: "claude", tty: false)
        #expect(ClaudeProvider(home: home.path, procs: procs).sessions(now: 0).isEmpty)
    }
}

// MARK: - Copilot

struct CopilotProviderTests {
    let t0 = "2026-11-08T15:00:00.000Z"
    func ts(_ s: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Time.parse(t0)! + s))
    }

    func event(_ type: String, _ at: Double, _ data: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "data": data, "timestamp": ts(at)]
    }

    func setup(_ events: [[String: Any]], args: [String] = ["copilot"]) -> (TempDir, CopilotProvider) {
        let home = TempDir()
        home.write(".copilot/session-state/abc/inuse.77.lock", "77")
        home.write(".copilot/session-state/abc/workspace.yaml", "id: abc\ncwd: /w/proj\nname: \"Ship it\"\n")
        home.write(".copilot/session-state/abc/events.jsonl", jsonl(events))
        home.write(".copilot/settings.json", "// comment\n{\"model\":\"gpt-5\",\"effortLevel\":\"low\"}")
        let procs = FakeProcs()
        procs.add(77, name: "copilot", args: args)
        return (home, CopilotProvider(home: home.path, procs: procs))
    }

    var base: Double { Time.parse(t0)! }

    @Test func turnEndGraceRule() throws {
        let (home, p) = setup([
            event("session.start", 0, ["selectedModel": "claude-opus-5.5", "reasoningEffort": "high"]),
            event("user.message", 10, ["content": "do it"]),
            event("assistant.turn_start", 11),
            event("session.usage_record", 12, ["usage": ["model": "claude-opus-5.5", "inputTokens": 1000, "outputTokens": 100,
                                                          "initiator": "user", "maxPromptTokens": 128_000]]),
            event("session.usage_record", 13, ["usage": ["inputTokens": 500, "outputTokens": 50, "initiator": "sub-agent"]]),
            event("assistant.turn_end", 20),
        ])
        defer { withExtendedLifetime(home) {} }
        var s = try #require(p.sessions(now: base + 21).first)
        #expect(s.state == .working) // within 2 s of turn_end
        #expect(s.since == base + 10)
        s = try #require(p.sessions(now: base + 23).first)
        #expect(s.state == .done)
        #expect(s.since == base + 20)
        #expect(s.title == "Ship it")
        #expect(s.cwd == "/w/proj")
        #expect(s.model == "claude-opus-5.5" && s.effort == "high")
        #expect(s.tin == 1500 && s.tout == 150)
        #expect(s.ctx == 1100 && s.ctxmax == 128_000)
        #expect(s.active == 9)
    }

    @Test func pendingPermissionAndQuestion() throws {
        let (home, p) = setup([
            event("user.message", 0, ["content": "go"]),
            event("assistant.turn_start", 1),
            event("tool.execution_start", 2, ["toolName": "ask_user", "toolCallId": "q1"]),
            event("permission.requested", 3, ["requestId": "r1"]),
        ])
        defer { withExtendedLifetime(home) {} }
        var s = try #require(p.sessions(now: base + 10).first)
        #expect(s.state == .input && s.waiting == "permission" && s.since == base + 2)
        home.append(".copilot/session-state/abc/events.jsonl", jsonl([event("permission.completed", 4, ["requestId": "r1"])]))
        s = try #require(p.sessions(now: base + 10).first)
        #expect(s.state == .input && s.waiting == "question")
        home.append(".copilot/session-state/abc/events.jsonl", jsonl([event("tool.execution_complete", 5, ["toolCallId": "q1", "result": ["content": "x"]])]))
        s = try #require(p.sessions(now: base + 10).first)
        #expect(s.state == .working)
    }

    @Test func subagentTurnsDontEndTheParentTurn() throws {
        func sub(_ type: String, _ at: Double) -> [String: Any] {
            ["type": type, "agentId": "a1", "data": ["parentToolCallId": "tc1", "content": "sub prompt"], "timestamp": ts(at)]
        }
        let (home, p) = setup([
            event("user.message", 0, ["content": "go"]),
            event("assistant.turn_start", 1),
            sub("user.message", 2), sub("assistant.turn_start", 2), sub("assistant.turn_end", 3),
        ])
        defer { withExtendedLifetime(home) {} }
        let s = try #require(p.sessions(now: base + 30).first)
        #expect(s.state == .working && s.since == base)
        #expect(s.active == 29)
    }

    @Test func readyAndDefaults() throws {
        let (home, p) = setup([])
        defer { withExtendedLifetime(home) {} }
        let s = try #require(p.sessions(now: base).first)
        #expect(s.state == .ready)
        #expect(s.model == "gpt-5" && s.effort == "low")
    }

    @Test func skipsPromptMode() {
        let (home, p) = setup([], args: ["copilot", "-p", "hello"])
        defer { withExtendedLifetime(home) {} }
        #expect(p.sessions(now: base).isEmpty)
    }
}

// MARK: - Codex

struct CodexProviderTests {
    func makeDB(_ path: String, rows: [(id: String, cwd: String, created: Int, updated: Int, rollout: String, role: String?, source: String)]) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER, source TEXT,
          cwd TEXT, title TEXT, archived INTEGER DEFAULT 0, first_user_message TEXT DEFAULT '', agent_role TEXT,
          model TEXT, reasoning_effort TEXT);
        """, nil, nil, nil)
        for r in rows {
            let role = r.role.map { "'\($0)'" } ?? "NULL"
            sqlite3_exec(db, "INSERT INTO threads VALUES ('\(r.id)', '\(r.rollout)', \(r.created), \(r.updated), '\(r.source)', '\(r.cwd)', 'Thread \(r.id)', 0, '', \(role), 'gpt-6', 'medium');", nil, nil, nil)
        }
        sqlite3_close(db)
    }

    func rollout(_ events: [(Double, [String: Any])]) -> String {
        jsonl(events.map { at, payload in
            ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at)), "type": "event_msg", "payload": payload]
        })
    }

    static let ids = (new: "019a0000-0000-7000-8000-00000000000a", old: "019a0000-0000-7000-8000-00000000000b",
                      mid: "019a0000-0000-7000-8000-00000000000c")

    @Test func discoveryAndFallbackMatching() throws {
        let home = TempDir()
        defer { withExtendedLifetime(home) {} }
        let r = home.write("r.jsonl", "")
        makeDB(home.path + "/.codex/state_5.sqlite", rows: [
            (Self.ids.new, "/w", 1985, 1990, r, nil, "cli"),
            (Self.ids.old, "/w", 1001, 1500, r, nil, "cli"),
            ("t-ide", "/w", 1986, 1999, r, nil, "vscode"),   // IDE thread: never claimed by the TUI
            ("t-sub", "/w", 1987, 1995, r, "worker", "cli"), // sub-agent thread
        ])
        home.write(".codex/session_index.jsonl", "{\"id\":\"\(Self.ids.new)\",\"thread_name\":\"Named thread\"}\n")
        home.write(".codex/config.toml", "model = \"gpt-5\"\nmodel_reasoning_effort = \"low\"\n[x]\nmodel = \"no\"\n")
        let procs = FakeProcs()
        procs.add(10, name: "codex", started: 1000, cwd: "/w")
        procs.add(11, name: "codex", started: 1980, cwd: "/w")
        procs.add(12, name: "codex", ppid: 11, started: 1981, cwd: "/w")             // re-exec child
        procs.add(13, name: "codex", started: 1000, args: ["codex", "exec", "hi"], cwd: "/w")
        procs.add(14, name: "codex", tty: false, started: 1000, cwd: "/w")
        procs.add(15, name: "codex", started: 2500, cwd: "/w")                        // no thread yet
        let p = CodexProvider(home: home.path, procs: procs, hookDir: home.path + "/hooks")
        let sessions = p.sessions(now: 2600)
        #expect(sessions.map(\.pid) == [10, 11, 15])
        // The older process doesn't steal the newer process's thread even though it was updated more recently.
        #expect(sessions[0].title == "Thread \(Self.ids.old)")
        #expect(sessions[1].title == "Named thread")
        #expect(sessions[1].model == "gpt-6" && sessions[1].effort == "medium")
        #expect(sessions[2].title == "" && sessions[2].state == .ready)
        #expect(sessions[2].model == "gpt-5" && sessions[2].effort == "low") // config.toml defaults
    }

    @Test func exactMatchFromOpenRollout() throws {
        let home = TempDir()
        defer { withExtendedLifetime(home) {} }
        let r = home.write(".codex/sessions/2026/11/09/rollout-2026-11-09T00-00-00-\(Self.ids.mid).jsonl", "")
        makeDB(home.path + "/.codex/state_5.sqlite", rows: [
            (Self.ids.new, "/w", 1985, 1990, r, nil, "cli"),
            (Self.ids.mid, "/w", 1001, 1100, r, nil, "cli"),
        ])
        let procs = FakeProcs()
        procs.add(10, name: "codex", started: 1000, cwd: "/w")
        procs.add(20, name: "codex", ppid: 10, tty: false, started: 1001, args: ["codex", "app-server"], files: [r])
        procs.add(11, name: "codex", started: 1980, cwd: "/w")
        let sessions = CodexProvider(home: home.path, procs: procs, hookDir: home.path + "/hooks").sessions(now: 2000)
        #expect(sessions.map(\.title) == ["Thread \(Self.ids.mid)", "Thread \(Self.ids.new)"])
    }

    @Test func rolloutStateAndHookPrecedence() throws {
        let home = TempDir()
        defer { withExtendedLifetime(home) {} }
        let r = home.write("r.jsonl", rollout([
            (2000, ["type": "task_started"]),
            (2001, ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 5000, "output_tokens": 300],
                                                     "last_token_usage": ["total_tokens": 5300], "model_context_window": 400_000]]),
        ]))
        makeDB(home.path + "/.codex/state_5.sqlite", rows: [("t1", "/w", 1995, 2000, r, nil, "cli")])
        let procs = FakeProcs()
        procs.add(10, name: "codex", started: 1990, cwd: "/w")
        let hooks = home.path + "/hooks"
        let p = CodexProvider(home: home.path, procs: procs, hookDir: hooks)

        var s = try #require(p.sessions(now: 2005).first)
        #expect(s.state == .working && s.since == 2000)
        #expect(s.tin == 5000 && s.tout == 300 && s.ctx == 5300 && s.ctxmax == 400_000)
        #expect(s.active == 5)

        CodexHooks.handle(input: Data(#"{"hook_event_name":"PermissionRequest","session_id":"t1","tool_name":"shell"}"#.utf8), dir: hooks, now: 2003)
        s = try #require(p.sessions(now: 2005).first)
        #expect(s.state == .input && s.waiting == "permission" && s.since == 2003)

        home.append("r.jsonl", rollout([(2008, ["type": "task_complete"])]))
        s = try #require(p.sessions(now: 2010).first)
        #expect(s.state == .done) // the hook record is now older than the rollout's state
        #expect(s.active == 8)
    }
}

// MARK: - Codex hooks

struct CodexHooksTests {
    @Test func mapping() {
        #expect(CodexHooks.state(event: "SessionStart", toolName: nil) == .ready)
        #expect(CodexHooks.state(event: "PreToolUse", toolName: "shell") == .working)
        #expect(CodexHooks.state(event: "PreToolUse", toolName: "request_user_input") == .input)
        #expect(CodexHooks.state(event: "PermissionRequest", toolName: nil) == .input)
        #expect(CodexHooks.state(event: "Stop", toolName: nil) == .done)
        #expect(CodexHooks.state(event: "SessionEnd", toolName: nil) == nil)
    }

    @Test func handleWritesAndDeletes() throws {
        let dir = TempDir()
        CodexHooks.handle(input: Data(#"{"hook_event_name":"PreToolUse","session_id":"../t9","tool_name":"ask_user"}"#.utf8), dir: dir.path, now: 5)
        let rec = try #require(CodexHooks.read(threadId: "t9", dir: dir.path))
        #expect(rec == CodexHooks.Record(state: "input", event: "PreToolUse", ts: 5))
        #expect(CodexHooks.waiting(for: rec) == "question")
        CodexHooks.handle(input: Data(#"{"hook_event_name":"SessionEnd","session_id":"t9"}"#.utf8), dir: dir.path)
        #expect(CodexHooks.read(threadId: "t9", dir: dir.path) == nil)
        CodexHooks.handle(input: Data("garbage".utf8), dir: dir.path) // must not crash
    }

    @Test func installKeepsUserHooks() throws {
        let dir = TempDir()
        let path = dir.write("hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/my/notify.sh"}]}]},"other":1}
        """)
        #expect(try CodexHooks.install(command: "/A/agent-monitor-hook", path: path))
        #expect(CodexHooks.isInstalled(path: path))
        #expect(try CodexHooks.install(command: "/A/agent-monitor-hook", path: path) == false) // idempotent
        let obj = try #require(JSON.object(file: path))
        let stop = try #require((obj["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/my/notify.sh")
        #expect(obj["other"] as? Int == 1)

        #expect(try CodexHooks.uninstall(path: path))
        let after = try #require(JSON.object(file: path)?["hooks"] as? [String: Any])
        #expect(after.keys.sorted() == ["Stop"])
        #expect(!CodexHooks.isInstalled(path: path))
    }

    @Test func commandIsNoOpWhenHelperIsMissing() throws {
        func sh(_ command: String) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.standardInput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        let dir = TempDir()
        let helper = dir.path + "/it's an app/agent-monitor-hook"
        #expect(try sh(CodexHooks.command(helper: helper)) == 0) // a bare missing path exits 127

        dir.write("it's an app/agent-monitor-hook", "#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\n")
        chmod(helper, 0o755)
        #expect(try sh(CodexHooks.command(helper: helper)) == 0)
        #expect(FileManager.default.fileExists(atPath: dir.path + "/it's an app/ran"))
        #expect(CodexHooks.command(helper: "/A/agent-monitor-hook") == "test -x /A/agent-monitor-hook && /A/agent-monitor-hook || true")
    }

    @Test func refusesToClobberInvalidJSON() {
        let dir = TempDir()
        let path = dir.write("hooks.json", "{ not json")
        #expect(throws: CodexHooks.InstallError.self) { try CodexHooks.install(command: "x/agent-monitor-hook", path: path) }
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "{ not json")
    }
}

// MARK: - Store and icons

struct StoreTests {
    @Test func idListOnlyChangesOnStartAndExit() {
        let store = SessionStore(home: "/h")
        var idEvents = 0, cardEvents = 0
        store.onIdsChanged = { _ in idEvents += 1 }
        store.onCardsChanged = { _ in cardEvents += 1 }
        let a = Session(kind: .codex, pid: 2, state: .working, started: 20)
        let b = Session(kind: .claude, pid: 9, state: .ready, started: 10)
        store.apply([a, b], now: 100)
        #expect(store.idList == ["claude-9", "codex-2"]) // ordered by start time
        var a2 = a
        a2.tout = 5000
        store.apply([a2, b], now: 100)
        store.apply([a2, b], now: 100) // no-op
        #expect(idEvents == 1 && cardEvents == 2)
        store.apply([b], now: 100)
        #expect(idEvents == 2 && store.idList == ["claude-9"])
    }

    @Test func iconsParseAndFit() {
        for kind in AgentKind.allCases {
            let box = AgentIcons.path(kind, size: 16).boundingBoxOfPath
            #expect(abs(max(box.width, box.height) - 16) < 0.01, "\(kind)")
            #expect(box.minX >= -0.01 && box.minY >= -0.01 && box.maxX <= 16.01 && box.maxY <= 16.01, "\(kind)")
        }
        let arc = SVGPath.parse("M0 0A5 5 0 0 1 10 0").boundingBoxOfPath
        #expect(abs(arc.width - 10) < 0.01 && abs(arc.height - 5) < 0.01)
    }
}
