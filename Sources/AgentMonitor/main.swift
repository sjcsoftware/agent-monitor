import AgentMonitorCore
import AppKit

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "dump":
    exit(Commands.dump())
case "hooks":
    exit(Commands.hooks(Array(args.dropFirst())))
case "transparent":
    exit(Commands.transparent(Array(args.dropFirst())))
case "preview":
    exit(Commands.preview(args.count > 1 ? args[1] : "preview.png", hovered: args.count > 2 ? Int(args[2]) ?? 0 : 0))
case "version", "--version", "-v":
    print(AppInfo.version)
    exit(0)
case nil, "run":
    break
default:
    fputs("usage: AgentMonitor [run|dump|hooks|transparent|version]\n", stderr)
    exit(2)
}

// One instance per user, however many login items or launch agents start us at once. An unbundled
// development build skips this so it can run beside the installed app. Exiting 0 keeps launchd's
// crash-only KeepAlive from relaunching the loser.
if Bundle.main.bundleIdentifier != nil, InstanceLock.acquire(at: InstanceLock.defaultPath) == .alreadyHeld {
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
