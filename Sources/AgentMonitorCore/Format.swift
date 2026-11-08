import Foundation

public enum Format {
    /// `<1000` as-is; `1.2k` below 10k, `84k` above; `1.5M` below 100M, `120M` above.
    public static func tokens(_ n: Int) -> String {
        let v = Double(Swift.max(0, n))
        if v < 1000 { return String(Int(v)) }
        if v < 9_950 { return trim(String(format: "%.1f", v / 1000)) + "k" }
        if v < 999_500 { return String(format: "%.0f", v / 1000) + "k" }
        if v < 99_950_000 { return trim(String(format: "%.1f", v / 1_000_000)) + "M" }
        return String(format: "%.0f", v / 1_000_000) + "M"
    }

    /// `42s`, `17m`, `2h 05m`.
    public static func duration(_ seconds: Double) -> String {
        let s = Int(Swift.min(Swift.max(0, seconds.isFinite ? seconds : 0), 1e9))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    /// `claude-opus-4-6-20260101` → `opus 4.6`; anything else as-is.
    public static func model(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        let lower = name.lowercased()
        guard lower.hasPrefix("claude-") else { return name }
        let parts = lower.dropFirst("claude-".count)
            .split(whereSeparator: { $0 == "-" || $0 == "." })
            .map(String.init)
        let families = ["opus", "sonnet", "haiku"]
        guard let family = parts.first(where: { families.contains($0) }) else { return name }
        // Version numbers are short digit groups; 8-digit dates are dropped.
        let version = parts.filter { $0.count <= 2 && Int($0) != nil }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }

    public static func project(_ cwd: String, home: String) -> String {
        if cwd.isEmpty { return "~" }
        let trimmed = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let homeTrimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        if trimmed == homeTrimmed { return "~" }
        return (trimmed as NSString).lastPathComponent
    }

    public static func stateText(_ state: SessionState, waiting: String) -> String {
        switch state {
        case .working: return "working"
        case .input: return waiting.isEmpty ? "needs you" : "needs you · \(waiting)"
        case .done: return "finished"
        case .ready: return "ready"
        }
    }

    /// `lo` < 50 %, `mid` 50–79 %, `hi` ≥ 80 %.
    public static func contextLevel(_ pct: Int) -> String {
        pct >= 80 ? "hi" : pct >= 50 ? "mid" : "lo"
    }

    /// First non-empty line, collapsed and cut to `limit` characters.
    public static func firstLine(_ text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static func trim(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
