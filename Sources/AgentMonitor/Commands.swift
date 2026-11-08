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
        return path.contains(" ") ? "'\(path)'" : path
    }
}

/// Non-GUI subcommands of the app binary (the `agent-monitor` script calls these).
enum Commands {
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

    /// Renders the strip and a hover card with sample sessions to a PNG (used for README images).
    static func preview(_ output: String) -> Int32 {
        _ = NSApplication.shared
        let now = Date().timeIntervalSince1970
        let samples = [
            Session(kind: .claude, pid: 1, cwd: "/Users/me/my-project", title: "Refactor the auth middleware",
                    model: "claude-opus-4-6", effort: "high", state: .input, waiting: "permission", since: now - 125,
                    started: now - 3000, active: 900, ctx: 84_000, ctxmax: 200_000, tin: 1_400_000, tout: 12_000),
            Session(kind: .codex, pid: 2, state: .working, started: now - 2000),
            Session(kind: .copilot, pid: 3, state: .done, started: now - 1000),
        ]
        let cards = samples.map { CardModel(session: $0, now: now) }

        let scale: CGFloat = 2
        let pill: CGFloat = 28, gap: CGFloat = 6
        let stripW = CGFloat(cards.count) * pill + CGFloat(cards.count - 1) * gap
        let margin: CGFloat = 24, barH: CGFloat = 34
        let canvas = NSSize(width: CardView.width + margin * 2 + stripW, height: barH + 4 + CardView.height + margin)
        let root = NSView(frame: NSRect(origin: .zero, size: canvas))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.crust.cgColor
        let bar = NSView(frame: NSRect(x: 0, y: canvas.height - barH, width: canvas.width, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.base.cgColor
        root.addSubview(bar)
        let stripX = (canvas.width - pill) / 2 // the hovered (first) pill sits in the middle
        var firstPill: NSRect = .zero
        for (i, c) in cards.enumerated() {
            let p = PillView(id: c.id, kind: c.kind, state: c.state)
            p.setSize(pill)
            p.frame = NSRect(x: stripX + CGFloat(i) * (pill + gap), y: (barH - pill) / 2, width: pill, height: pill)
            bar.addSubview(p)
            if i == 0 { firstPill = p.frame }
        }
        let cardView = CardView(frame: NSRect(x: firstPill.midX - CardView.width / 2,
                                              y: canvas.height - barH - 4 - CardView.height,
                                              width: CardView.width, height: CardView.height))
        cardView.opaqueBackground = true
        cardView.model = cards[0]
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
