import Darwin
import Foundation

public struct ProcInfo: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// Executable name as the kernel records it (≤ 32 chars).
    public var name: String
    /// Has a controlling terminal.
    public var hasTTY: Bool
    public var tdev: UInt32
    /// Process start, epoch seconds.
    public var started: Double

    public init(pid: Int32, ppid: Int32, name: String, hasTTY: Bool, tdev: UInt32 = 0, started: Double) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.hasTTY = hasTTY
        self.tdev = tdev
        self.started = started
    }
}

/// Process inspection, abstracted so providers can be tested against fake process tables.
public protocol ProcessInspecting: AnyObject {
    func allPids() -> [Int32]
    /// `nil` when the process is gone (or a zombie).
    func info(_ pid: Int32) -> ProcInfo?
    func arguments(_ pid: Int32) -> [String]
    func environment(_ pid: Int32) -> [String: String]
    func executablePath(_ pid: Int32) -> String?
    func cwd(_ pid: Int32) -> String?
    /// Paths of regular files the process has open.
    func openFiles(_ pid: Int32) -> [String]
}

public extension ProcessInspecting {
    /// True if the process's name, argv[0], or executable path identifies it as `tool`.
    func looksLike(_ pid: Int32, tool: String) -> Bool {
        if let info = info(pid), info.name == tool { return true }
        let args = arguments(pid)
        if let arg0 = args.first, (arg0 as NSString).lastPathComponent == tool { return true }
        if let path = executablePath(pid), path.contains("/\(tool)") { return true }
        // Script launchers (node/bun) carry the tool in the first couple of arguments.
        return args.prefix(3).dropFirst().contains { $0.contains("/\(tool)") || $0 == tool }
    }
}

/// Live process table via libproc and sysctl — no subprocesses.
public final class SystemProcesses: ProcessInspecting {
    private struct ArgsEntry { var started: Double; var args: [String]; var env: [String: String] }
    private var argsCache: [Int32: ArgsEntry] = [:]
    private let lock = NSLock()

    public init() {}

    public func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    public func info(_ pid: Int32) -> ProcInfo? {
        guard pid > 0 else { return nil }
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        if bi.pbi_status == 5 /* SZOMB */ { return nil }
        let long = Self.cString(bi.pbi_name)
        let name = long.isEmpty ? Self.cString(bi.pbi_comm) : long
        let noDevice = UInt32.max
        return ProcInfo(
            pid: pid,
            ppid: Int32(bi.pbi_ppid),
            name: name,
            hasTTY: bi.e_tdev != noDevice && bi.e_tdev != 0,
            tdev: bi.e_tdev,
            started: Double(bi.pbi_start_tvsec) + Double(bi.pbi_start_tvusec) / 1_000_000
        )
    }

    public func arguments(_ pid: Int32) -> [String] { procArgs(pid)?.args ?? [] }

    public func environment(_ pid: Int32) -> [String: String] { procArgs(pid)?.env ?? [:] }

    public func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public func cwd(_ pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        let path = Self.cString(vpi.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    public func openFiles(_ pid: Int32) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var paths: [String] = []
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, infoSize) == infoSize else { continue }
            let path = Self.cString(vi.pvip.vip_path)
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// `/dev/ttys003` for a controlling-terminal device number.
    public static func ttyPath(_ tdev: UInt32) -> String? {
        guard tdev != UInt32.max, tdev != 0, let name = devname(dev_t(bitPattern: tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    // MARK: - argv / environment (KERN_PROCARGS2), cached per process lifetime

    private func procArgs(_ pid: Int32) -> ArgsEntry? {
        guard let started = info(pid)?.started else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = argsCache[pid], hit.started == started { return hit }
        guard let fresh = Self.readProcArgs(pid) else { return nil }
        if argsCache.count > 256 { argsCache.removeAll() }
        let entry = ArgsEntry(started: started, args: fresh.0, env: fresh.1)
        argsCache[pid] = entry
        return entry
    }

    private static func readProcArgs(_ pid: Int32) -> ([String], [String: String])? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
        var size = Int(argmax)
        var buf = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 } // exec path
        while i < size, buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        var env: [String: String] = [:]
        var start = i
        while i < size {
            if buf[i] == 0 {
                let s = String(decoding: buf[start..<i], as: UTF8.self)
                if args.count < argc {
                    args.append(s)
                } else {
                    if s.isEmpty { break }
                    if let eq = s.firstIndex(of: "=") {
                        env[String(s[..<eq])] = String(s[s.index(after: eq)...])
                    }
                }
                start = i + 1
            }
            i += 1
        }
        return (args, env)
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
    }
}
