import AgentMonitorCore
import AppKit

enum AppInfo {
    static let bundleID = "com.sjcsoftware.agent-monitor"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The hook helper ships next to the main executable.
    static var hookCommand: String {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let path = exe.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(CodexHooks.helperName).path
        return CodexHooks.command(helper: path)
    }
}

/// User settings, stored in the app's defaults domain. Changes are broadcast so a running instance applies them live.
enum Settings {
    static let changed = Notification.Name("com.sjcsoftware.agent-monitor.settings")
    private static let transparencyKey = "transparency"

    /// Matches the card's original frosted look.
    static let defaultTransparency = 40

    /// Hover card background transparency: 0 = solid, 100 = frosted glass (the backdrop is always blurred).
    static var transparency: Int {
        get { min(max(UserDefaults.standard.object(forKey: transparencyKey) as? Int ?? defaultTransparency, 0), 100) }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 100), forKey: transparencyKey)
            UserDefaults.standard.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                changed, object: nil, userInfo: [transparencyKey: transparency], deliverImmediately: true)
        }
    }

    static func transparency(from note: Notification) -> Int {
        (note.userInfo?[transparencyKey] as? Int).map { min(max($0, 0), 100) } ?? transparency
    }
}

/// Non-GUI subcommands of the app binary (the `agent-monitor` script calls these).
enum Commands {
    /// `transparent` prints the current value; `transparent <0-100>` sets it.
    static func transparent(_ args: [String]) -> Int32 {
        guard let arg = args.first else {
            print(Settings.transparency)
            return 0
        }
        guard args.count == 1, let value = Int(arg), (0...100).contains(value) else {
            fputs("usage: agent-monitor transparent <0-100>   (0 = solid, 100 = most transparent; default \(Settings.defaultTransparency))\n", stderr)
            return 2
        }
        Settings.transparency = value
        print("Hover card transparency set to \(value).")
        return 0
    }

    /// Prints one JSON snapshot of every session's card model.
    static func dump() -> Int32 {
        let now = Date().timeIntervalSince1970
        let cards = SessionStore.orderedCards(Collector.standard().collect(now: now), now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(cards) else { return 1 }
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    static func hooks(_ args: [String]) -> Int32 {
        do {
            switch args.first ?? "status" {
            case "install":
                let changed = try CodexHooks.install(command: AppInfo.hookCommand)
                print(changed ? "Codex hooks installed in \(CodexHooks.hooksFile()). Codex will ask you to trust them once."
                              : "Codex hooks are already installed.")
            case "uninstall", "remove":
                let changed = try CodexHooks.uninstall()
                print(changed ? "Codex hooks removed." : "Codex hooks were not installed.")
            case "status":
                print(CodexHooks.isInstalled() ? "installed" : "not installed")
            default:
                fputs("usage: agent-monitor hooks [install|uninstall|status]\n", stderr)
                return 2
            }
            return 0
        } catch {
            fputs("error: \(error)\n", stderr)
            return 1
        }
    }

    /// Renders the strip with the hover card of sample session `hovered` (0–2) to a PNG (README images).
    static func preview(_ output: String, hovered: Int = 0) -> Int32 {
        _ = NSApplication.shared
        let now = Date().timeIntervalSince1970
        let samples = [
            Session(kind: .claude, pid: 1, cwd: "/Users/me/my-project", title: "Refactor the auth middleware",
                    model: "claude-opus-4-6", effort: "high", state: .input, waiting: "permission", since: now - 125,
                    started: now - 3000, active: 900, ctx: 84_000, ctxmax: 200_000, tin: 1_400_000, tout: 12_000),
            Session(kind: .codex, pid: 2, cwd: "/Users/me/api-server", title: "Add rate limiting to the API",
                    model: "gpt-5-codex", effort: "medium", state: .working, since: now - 47,
                    started: now - 2000, active: 700, ctx: 151_000, ctxmax: 272_000, tin: 2_300_000, tout: 31_000),
            Session(kind: .copilot, pid: 3, cwd: "/Users/me/web-app", title: "Fix the flaky login test",
                    model: "claude-sonnet-4.5", effort: "high", state: .done, since: now - 380,
                    started: now - 1000, active: 420, ctx: 172_000, ctxmax: 200_000, tin: 980_000, tout: 8_400),
        ]
        let index = min(max(hovered, 0), samples.count - 1)
        let cards = samples.map { CardModel(session: $0, now: now) }

        let scale: CGFloat = 2
        let pill: CGFloat = 28, gap: CGFloat = 6
        let margin: CGFloat = 24, barH: CGFloat = 34
        let canvas = NSSize(width: CardView.width + margin * 2, height: barH + 4 + CardView.height + margin)
        let root = NSView(frame: NSRect(origin: .zero, size: canvas))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.crust.cgColor
        let bar = NSView(frame: NSRect(x: 0, y: canvas.height - barH, width: canvas.width, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.base.cgColor
        root.addSubview(bar)
        let stripX = (canvas.width - pill) / 2 - CGFloat(index) * (pill + gap) // the hovered pill sits in the middle
        var hoveredPill: NSRect = .zero
        for (i, c) in cards.enumerated() {
            let p = PillView(id: c.id, kind: c.kind, state: c.state)
            p.setSize(pill)
            p.frame = NSRect(x: stripX + CGFloat(i) * (pill + gap), y: (barH - pill) / 2, width: pill, height: pill)
            bar.addSubview(p)
            if i == index { hoveredPill = p.frame }
        }
        let cardView = CardView(frame: NSRect(x: hoveredPill.midX - CardView.width / 2,
                                              y: canvas.height - barH - 4 - CardView.height,
                                              width: CardView.width, height: CardView.height))
        cardView.opaqueBackground = true
        cardView.model = cards[index]
        root.addSubview(cardView)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: canvas),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        cardView.layout()
        root.display()
        CATransaction.flush()
        func contents(_ v: NSView) { v.layer?.setNeedsDisplay(); v.layer?.displayIfNeeded(); v.subviews.forEach(contents) }
        contents(root)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return 1 }
        rep.size = canvas
        ctx.cgContext.scaleBy(x: scale, y: scale)
        root.layer?.render(in: ctx.cgContext)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: URL(fileURLWithPath: output)) } catch { return 1 }
        print(output)
        return 0
    }
}
