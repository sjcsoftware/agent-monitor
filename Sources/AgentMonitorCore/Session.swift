import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, copilot
}

public enum SessionState: String, Codable, Sendable {
    case working, input, done, ready

    /// Higher wins when signals conflict: input > working > done > ready.
    public var priority: Int {
        switch self {
        case .input: return 3
        case .working: return 2
        case .done: return 1
        case .ready: return 0
        }
    }
}

/// Raw per-session data produced by a provider.
public struct Session: Equatable, Sendable {
    public var kind: AgentKind
    public var pid: Int32
    public var cwd: String
    public var title: String
    public var model: String
    public var effort: String
    public var state: SessionState
    /// "" | "permission" | "question"
    public var waiting: String
    /// Epoch seconds when the session entered its current state.
    public var since: Double
    /// Process start, epoch seconds.
    public var started: Double
    /// Seconds spent in turns (including the running one).
    public var active: Double
    public var ctx: Int
    public var ctxmax: Int
    public var tin: Int
    public var tout: Int

    public var id: String { "\(kind.rawValue)-\(pid)" }

    public init(kind: AgentKind, pid: Int32, cwd: String = "", title: String = "", model: String = "",
                effort: String = "", state: SessionState = .ready, waiting: String = "", since: Double = 0,
                started: Double = 0, active: Double = 0, ctx: Int = 0, ctxmax: Int = 0, tin: Int = 0, tout: Int = 0) {
        self.kind = kind
        self.pid = pid
        self.cwd = cwd
        self.title = title
        self.model = model
        self.effort = effort
        self.state = state
        self.waiting = waiting
        self.since = since
        self.started = started
        self.active = active
        self.ctx = ctx
        self.ctxmax = ctxmax
        self.tin = tin
        self.tout = tout
    }
}

/// View model for one session: everything pre-formatted so views stay dumb.
public struct CardModel: Equatable, Codable, Sendable {
    public var id: String
    public var kind: AgentKind
    public var pid: Int32
    public var title: String
    public var proj: String
    public var model: String
    public var effort: String
    public var state: SessionState
    public var statetext: String
    public var since: String
    public var ctx: String
    public var ctxmax: String
    public var ctxpct: Int
    public var ctxlevel: String
    public var tin: String
    public var tout: String
    public var age: String
    public var active: String
    public var actpct: Int

    public init(session s: Session, now: Double, home: String = NSHomeDirectory()) {
        id = s.id
        kind = s.kind
        pid = s.pid
        title = s.title.isEmpty ? "new session" : s.title
        proj = Format.project(s.cwd, home: home)
        model = Format.model(s.model)
        effort = s.effort
        state = s.state
        statetext = Format.stateText(s.state, waiting: s.waiting)
        since = Format.duration(now - s.since)
        let max = s.ctxmax > 0 ? s.ctxmax : 1
        ctx = Format.tokens(s.ctx)
        ctxmax = Format.tokens(s.ctxmax)
        ctxpct = Int(Swift.min(100, Swift.max(0, Double(s.ctx) * 100 / Double(max))).rounded())
        ctxlevel = Format.contextLevel(ctxpct)
        tin = Format.tokens(s.tin)
        tout = Format.tokens(s.tout)
        let ageSeconds = Swift.max(0, now - s.started)
        age = Format.duration(ageSeconds)
        active = Format.duration(s.active)
        let activePct = ageSeconds > 0 ? s.active * 100 / ageSeconds : 0
        actpct = activePct.isFinite ? Int(Swift.min(100, Swift.max(0, activePct)).rounded()) : 0
    }

    /// `84k / 200k · 42%`
    public var contextText: String { "\(ctx) / \(ctxmax) · \(ctxpct)%" }
}
