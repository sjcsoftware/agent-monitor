// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CodexHookKit",
            path: "Sources/CodexHookKit"
        ),
        .target(
            name: "AgentMonitorCore",
            dependencies: ["CodexHookKit"],
            path: "Sources/AgentMonitorCore"
        ),
        .executableTarget(
            name: "AgentMonitor",
            dependencies: ["AgentMonitorCore"],
            path: "Sources/AgentMonitor"
        ),
        .executableTarget(
            name: "agent-monitor-hook",
            dependencies: ["CodexHookKit"],
            path: "Sources/AgentMonitorHook"
        ),
        .testTarget(
            name: "AgentMonitorCoreTests",
            dependencies: ["AgentMonitorCore"],
            path: "Tests/AgentMonitorCoreTests"
        ),
    ]
)
