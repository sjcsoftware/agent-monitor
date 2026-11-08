import Foundation

/// Incremental reader for an append-only JSONL file: remembers the byte offset, yields only new
/// complete lines and buffers a trailing partial line. Resets when the file shrinks or is replaced.
public final class LineTail {
    public let path: String
    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var partial = Data()

    public init(path: String) {
        self.path = path
    }

    /// Reads appended lines. Returns `true` if the file was reset (caller should drop derived state
    /// *before* consuming the lines passed to `body`).
    @discardableResult
    public func read(onReset: () -> Void = {}, _ body: (Data) -> Void) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        let size = UInt64(st.st_size)
        let ino = UInt64(st.st_ino)
        var reset = false
        if ino != inode || size < offset {
            if inode != 0 || offset != 0 { reset = true }
            inode = ino
            offset = 0
            partial.removeAll(keepingCapacity: false)
            if reset { onReset() }
        }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return reset }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let chunkSize = 4 << 20
            while true {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                consume(chunk, body)
                if chunk.count < chunkSize { break }
            }
        } catch {
            return reset
        }
        return reset
    }

    private func consume(_ chunk: Data, _ body: (Data) -> Void) {
        var data = chunk
        if !partial.isEmpty {
            data = partial + chunk
            partial.removeAll(keepingCapacity: false)
        }
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            if nl > start { body(data[start..<nl]) }
            start = data.index(after: nl)
        }
        if start < data.endIndex { partial = Data(data[start...]) }
    }
}

public enum JSON {
    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func object(file path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return object(data)
    }

    /// Whole numbers clamped to ±1e12 so sums of corrupted values can't overflow.
    public static func int(_ value: Any?) -> Int {
        let d: Double
        switch value {
        case let n as NSNumber: d = n.doubleValue
        case let s as String: d = Double(s) ?? 0
        default: return 0
        }
        guard d.isFinite else { return 0 }
        return Int(Swift.min(Swift.max(d, -1e12), 1e12))
    }

    /// Finite numbers clamped to ±1e15.
    public static func double(_ value: Any?) -> Double? {
        let d: Double?
        switch value {
        case let n as NSNumber: d = n.doubleValue
        case let s as String: d = Double(s)
        default: d = nil
        }
        guard let d, d.isFinite else { return nil }
        return Swift.min(Swift.max(d, -1e15), 1e15)
    }

    public static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Fast substring check on raw bytes (used to pre-filter lines before decoding).
    public static func contains(_ line: Data, _ needle: Data) -> Bool {
        line.range(of: needle) != nil
    }

    /// Value of the first `"key":"value"` occurrence, without decoding the whole line.
    public static func scanString(_ line: Data, key: String) -> String? {
        let needle = Data("\"\(key)\":\"".utf8)
        guard let r = line.range(of: needle) else { return nil }
        guard let end = line[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: line[r.upperBound..<end], as: UTF8.self)
    }
}

public enum Time {
    /// Epoch seconds from ISO-8601 (`2026-11-08T15:11:18.526Z`, offsets allowed).
    public static func parse(_ s: String?) -> Double? {
        guard let s, s.count >= 19 else { return nil }
        let u = Array(s.utf8)
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b {
                let c = Int(u[i]) - 48
                guard c >= 0, c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16), let sec = num(17, 19) else { return nil }
        var t = tm()
        t.tm_year = Int32(y - 1900)
        t.tm_mon = Int32(mo - 1)
        t.tm_mday = Int32(d)
        t.tm_hour = Int32(h)
        t.tm_min = Int32(mi)
        t.tm_sec = Int32(sec)
        var value = Double(timegm(&t))
        var i = 19
        if i < u.count, u[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                value += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        if i < u.count, u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-"), u.count >= i + 6,
           let oh = num(i + 1, i + 3), let om = num(i + 4, i + 6) {
            let sign: Double = u[i] == UInt8(ascii: "+") ? 1 : -1
            value -= sign * Double(oh * 3600 + om * 60)
        }
        return value
    }

    /// Accepts epoch seconds or milliseconds.
    public static func epoch(_ value: Any?) -> Double? {
        if let s = value as? String, let iso = parse(s) { return iso }
        guard let v = JSON.double(value), v > 0 else { return nil }
        return v > 100_000_000_000 ? v / 1000 : v
    }
}

/// mtime-keyed cache for small, rarely changing files.
public final class FileCache<Value> {
    private var entries: [String: (mtime: Double, value: Value?)] = [:]
    private let parse: (String) -> Value?

    public init(_ parse: @escaping (String) -> Value?) {
        self.parse = parse
    }

    public func get(_ path: String) -> Value? {
        var st = stat()
        guard stat(path, &st) == 0 else {
            entries[path] = nil
            return nil
        }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9 + Double(st.st_size)
        if let hit = entries[path], hit.mtime == mtime { return hit.value }
        let value = parse(path)
        entries[path] = (mtime, value)
        return value
    }

    public func retain(_ keep: Set<String>) {
        entries = entries.filter { keep.contains($0.key) }
    }
}

public func fileMTime(_ path: String) -> Double? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
}
