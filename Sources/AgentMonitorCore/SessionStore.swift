import Foundation

/// Holds the latest sessions and publishes two independent streams (DESIGN §2.2):
/// `idList` (changes only when sessions start/exit) and `cards` (changes on any detail).
public final class SessionStore {
    public private(set) var idList: [String] = []
    public private(set) var cards: [String: CardModel] = [:]
    public private(set) var sessions: [String: Session] = [:]
    public var onIdsChanged: (([String]) -> Void)?
    public var onCardsChanged: (([String: CardModel]) -> Void)?
    private let home: String

    public init(home: String = Paths.home) {
        self.home = home
    }

    public func apply(_ list: [Session], now: Double) {
        let ordered = list.sorted { ($0.started, $0.id) < ($1.started, $1.id) }
        sessions = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = ordered.map(\.id)
        let newCards = Dictionary(ordered.map { ($0.id, CardModel(session: $0, now: now, home: home)) }, uniquingKeysWith: { a, _ in a })
        if ids != idList {
            idList = ids
            cards = newCards
            onIdsChanged?(ids)
            onCardsChanged?(newCards)
        } else if newCards != cards {
            cards = newCards
            onCardsChanged?(newCards)
        }
    }

    public static func orderedCards(_ sessions: [Session], now: Double, home: String = Paths.home) -> [CardModel] {
        sessions.sorted { ($0.started, $0.id) < ($1.started, $1.id) }.map { CardModel(session: $0, now: now, home: home) }
    }
}

/// Polls every provider once per second on a background queue; each provider is isolated.
public final class Collector {
    public let providers: [AgentProvider]
    private let queue = DispatchQueue(label: "com.sjcsoftware.agent-monitor.collector", qos: .utility)
    private var timer: DispatchSourceTimer?

    public init(providers: [AgentProvider]) {
        self.providers = providers
    }

    public static func standard(procs: ProcessInspecting = SystemProcesses(), home: String = Paths.home) -> Collector {
        Collector(providers: [
            ClaudeProvider(home: home, procs: procs),
            CodexProvider(home: home, procs: procs, windowProbe: WindowProbe(procs: procs)),
            CopilotProvider(home: home, procs: procs),
        ])
    }

    public func collect(now: Double = Date().timeIntervalSince1970) -> [Session] {
        providers.flatMap { $0.sessions(now: now) }
    }

    /// Calls `publish` on the main queue after every tick.
    public func start(interval: Double = 1, publish: @escaping ([Session], Double) -> Void) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            let sessions = self.collect(now: now)
            DispatchQueue.main.async { publish(sessions, now) }
        }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
