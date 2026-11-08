import AgentMonitorCore
import AppKit

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "dump":
    exit(Commands.dump())
case "hooks":
    exit(Commands.hooks(Array(args.dropFirst())))
case "preview":
    exit(Commands.preview(args.dropFirst().first ?? "preview.png"))
case "version", "--version", "-v":
    print(AppInfo.version)
    exit(0)
case nil, "run":
    break
default:
    fputs("usage: AgentMonitor [run|dump|hooks|version]\n", stderr)
    exit(2)
}

// One instance per user session.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    fputs("Agent Monitor is already running.\n", stderr)
    exit(0)
}

// Exit cleanly (status 0) on SIGTERM/SIGINT so launchd's crash-only KeepAlive doesn't restart us.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
