import AgentMonitorCore
import AppKit
import ApplicationServices

/// Finds and raises the terminal window hosting a session (GUIDE §5). Results are cached per pid.
final class TerminalLocator {
    private struct Target {
        var app: NSRunningApplication
        var tty: String?
        var env: [String: String]
        var tmux: Tmux?
    }

    private struct Tmux {
        var binary: String
        var socket: String
        var pane: String
        var clientTTY: String?

        func command(_ args: [String]) -> (String, [String]) {
            binary.hasSuffix("/env") ? (binary, ["tmux", "-S", socket] + args) : (binary, ["-S", socket] + args)
        }
    }

    private let procs: SystemProcesses
    private var cache: [Int32: Target] = [:]

    init(procs: SystemProcesses) {
        self.procs = procs
    }

    func prune(alive: Set<Int32>) {
        cache = cache.filter { alive.contains($0.key) }
    }

    func focus(_ session: Session) {
        guard let target = cache[session.pid].flatMap({ $0.app.isTerminated ? nil : $0 }) ?? resolve(session.pid) else { return }
        cache[session.pid] = target
        if let tmux = target.tmux { selectTmuxPane(tmux) }
        let bundle = target.app.bundleIdentifier ?? ""
        switch bundle {
        case "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty":
            if let tty = target.tty, let script = Self.focusScript(bundle: bundle, tty: tty), runAppleScript(script) { return }
        case "net.kovidgoyal.kitty":
            if let id = target.env["KITTY_WINDOW_ID"], let socket = target.env["KITTY_LISTEN_ON"] {
                run(bundleBinary(target.app, "kitty"), ["@", "--to", socket, "focus-window", "--match", "id:\(id)"])
            }
        case "com.github.wez.wezterm":
            if let pane = target.env["WEZTERM_PANE"] {
                run(bundleBinary(target.app, "wezterm"), ["cli", "activate-pane", "--pane-id", pane])
            }
        default:
            break
        }
        activate(target.app)
        raiseWindow(of: target.app, matching: [session.title, Format.project(session.cwd, home: Paths.home)])
    }

    // MARK: - Resolution

    private func resolve(_ pid: Int32) -> Target? {
        let env = procs.environment(pid)
        var tty = procs.info(pid).flatMap { SystemProcesses.ttyPath($0.tdev) }
        var start = pid
        var tmux: Tmux?
        if let tmuxVar = env["TMUX"], let pane = env["TMUX_PANE"] {
            let socket = String(tmuxVar.split(separator: ",").first ?? "")
            let server = Int32(tmuxVar.split(separator: ",").dropFirst().first ?? "") ?? 0
            let binary = procs.executablePath(server) ?? "/usr/bin/env"
            var t = Tmux(binary: binary, socket: socket, pane: pane)
            let client = tmuxClient(t)
            t.clientTTY = client?.tty
            tmux = t
            if let client {
                start = client.pid
                tty = client.tty
            }
        }
        guard let app = guiAncestor(of: start) else { return nil }
        return Target(app: app, tty: tty, env: env, tmux: tmux)
    }

    /// First ancestor (≤ 12 levels) that is a regular GUI app.
    private func guiAncestor(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 {
            guard let info = procs.info(current), info.ppid > 1 else { return nil }
            current = info.ppid
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
        }
        return nil
    }

    /// The most recently active tmux client attached to the pane's session.
    private func tmuxClient(_ t: Tmux) -> (pid: Int32, tty: String)? {
        let (binary, args) = t.command(["list-clients", "-t", t.pane, "-F", "#{client_activity} #{client_pid} #{client_tty}"])
        guard let out = capture(binary, args) else { return nil }
        var best: (activity: Int, pid: Int32, tty: String)?
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 3, let pid = Int32(f[1]) else { continue }
            let activity = Int(f[0]) ?? 0
            if best == nil || activity > best!.activity { best = (activity, pid, f[2]) }
        }
        return best.map { ($0.pid, $0.tty) }
    }

    private func selectTmuxPane(_ t: Tmux) {
        var args: [String] = []
        if let client = t.clientTTY { args += ["switch-client", "-c", client, "-t", t.pane, ";"] }
        args += ["select-window", "-t", t.pane, ";", "select-pane", "-t", t.pane]
        let (binary, full) = t.command(args)
        run(binary, full)
    }

    // MARK: - Focusing

    private func activate(_ app: NSRunningApplication) {
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app.activate()
        }
    }

    /// Raises the window whose title mentions the session (needs Accessibility; silently skipped otherwise).
    private func raiseWindow(of app: NSRunningApplication, matching hints: [String]) {
        guard AXIsProcessTrusted() else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let needles = hints.filter { $0.count > 1 && $0 != "~" && $0 != "new session" }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let t = title as? String, needles.contains(where: { t.localizedCaseInsensitiveContains($0) }) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
    }

    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    /// AppleScript that selects the tab/split whose tty matches and brings its window to the front.
    static func focusScript(bundle: String, tty: String) -> String? {
        guard tty.hasPrefix("/dev/"), !tty.contains("\"") else { return nil }
        let body: String
        switch bundle {
        case "com.apple.Terminal":
            body = """
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            """
        case "com.googlecode.iterm2":
            body = """
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            """
        case "com.mitchellh.ghostty":
            // Ghostty 1.3+ scripting: `focus` selects the split/tab and raises its window.
            body = """
                repeat with t in terminals
                    if tty of t is "\(tty)" then
                        focus t
                        activate
                        return true
                    end if
                end repeat
            """
        default:
            return nil
        }
        return "tell application id \"\(bundle)\"\n\(body)\nend tell\nreturn false"
    }

    private func bundleBinary(_ app: NSRunningApplication, _ name: String) -> String {
        app.bundleURL?.appendingPathComponent("Contents/MacOS/\(name)").path ?? name
    }

    private func run(_ binary: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func capture(_ binary: String, _ args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
