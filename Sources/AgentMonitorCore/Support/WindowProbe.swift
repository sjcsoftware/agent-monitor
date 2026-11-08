import CoreGraphics
import Foundation

/// Window titles of the terminal hosting a process. Titles are only visible to apps with Screen
/// Recording access; without it this quietly returns nothing.
public final class WindowProbe {
    private let procs: ProcessInspecting
    private var titlesByOwner: [Int32: [String]] = [:]

    public init(procs: ProcessInspecting) {
        self.procs = procs
    }

    /// Call once per tick before `titles(for:)`.
    public func refresh() {
        titlesByOwner.removeAll(keepingCapacity: true)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32,
                  let name = w[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            titlesByOwner[owner, default: []].append(name)
        }
    }

    public func titles(for pid: Int32) -> [String] {
        guard !titlesByOwner.isEmpty else { return [] }
        var current = pid
        for _ in 0..<12 {
            guard let info = procs.info(current), info.ppid > 1 else { return [] }
            current = info.ppid
            if let titles = titlesByOwner[current] { return titles }
        }
        return []
    }
}
