import AgentMonitorCore
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let procs = SystemProcesses()
    private let store = SessionStore()
    private lazy var collector = Collector.standard(procs: procs)
    private lazy var locator = TerminalLocator(procs: procs)
    private var strip: StripController!
    private var card: CardController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        strip = StripController()
        card = CardController()

        strip.onHover = { [weak self] id, pill, inside in
            guard let self else { return }
            if inside, let model = self.store.cards[id] {
                self.card.show(model, anchor: pill)
            } else if !inside, self.card.shownId == id {
                self.card.hide()
            }
        }
        strip.onClick = { [weak self] id in
            guard let self else { return }
            self.card.hide()
            if let session = self.store.sessions[id] { self.locator.focus(session) }
        }
        strip.onMenu = { [weak self] pill, event in
            guard let self else { return }
            self.card.hide()
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: pill)
        }
        strip.onLayout = { [weak self] in self?.card.reposition() }

        store.onIdsChanged = { [weak self] ids in
            guard let self else { return }
            if let shown = self.card.shownId, !ids.contains(shown) { self.card.hide() }
            self.strip.setIds(ids, cards: self.store.cards)
        }
        store.onCardsChanged = { [weak self] cards in
            self?.strip.update(cards)
            self?.card.update(cards)
        }

        collector.start { [weak self] sessions, now in
            guard let self else { return }
            self.store.apply(sessions, now: now)
            self.locator.prune(alive: Set(sessions.map(\.pid)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.offerCodexHooks() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        collector.stop()
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Agent Monitor \(AppInfo.version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let hooks = NSMenuItem(title: "Codex Approval Hooks", action: #selector(toggleCodexHooks), keyEquivalent: "")
        hooks.target = self
        hooks.state = CodexHooks.isInstalled() ? .on : .off
        menu.addItem(hooks)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleCodexHooks() {
        do {
            if CodexHooks.isInstalled() {
                try CodexHooks.uninstall()
            } else {
                try CodexHooks.install(command: AppInfo.hookCommand)
            }
        } catch {
            alert("Couldn't update Codex hooks", "\(error)")
        }
    }

    /// One-time offer to install the Codex hooks that surface approval prompts.
    private func offerCodexHooks() {
        let key = "codexHooksOffered"
        let codexDir = (Paths.home as NSString).appendingPathComponent(".codex")
        guard !UserDefaults.standard.bool(forKey: key),
              FileManager.default.fileExists(atPath: codexDir),
              !CodexHooks.isInstalled() else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Show when Codex needs your approval?"
        a.informativeText = """
        Agent Monitor can add a tiny hook to ~/.codex/hooks.json so it knows when Codex is waiting on an \
        approval. Your existing hooks are kept. Codex asks you to trust the new hooks once.

        You can change this later from the strip's right-click menu or with `agent-monitor hooks`.
        """
        a.addButton(withTitle: "Install Hooks")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn {
            do { try CodexHooks.install(command: AppInfo.hookCommand) } catch { alert("Couldn't install Codex hooks", "\(error)") }
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
