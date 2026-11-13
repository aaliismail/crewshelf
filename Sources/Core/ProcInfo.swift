import Darwin
import Foundation

// The process table, read with sysctl (no `ps`, no fork): parents, short names and controlling ttys. Compiled into
// the hook client too, so Foundation only.

public struct ProcEntry: Equatable {
    public var pid: Int
    public var ppid: Int
    public var comm: String          // short name (at most 16 characters)
    public var tty: String?          // controlling terminal, "ttys003"; nil when none
    public init(pid: Int, ppid: Int, comm: String, tty: String?) {
        self.pid = pid; self.ppid = ppid; self.comm = comm; self.tty = tty
    }
}

public func procEntry(_ pid: Int) -> ProcEntry? {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == Int32(pid) else { return nil }
    let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    var tty: String?
    let dev = info.kp_eproc.e_tdev
    if dev != -1, let name = devname(dev, S_IFCHR) {
        let n = String(cString: name)
        if n.hasPrefix("tty") { tty = n }
    }
    return ProcEntry(pid: pid, ppid: Int(info.kp_eproc.e_ppid), comm: comm, tty: tty)
}

/// `pid` and its parents, nearest first, up to (not including) launchd. Stops early at a loop or after `max`.
public func ancestry(_ pid: Int, max: Int = 16, lookup: (Int) -> ProcEntry? = procEntry) -> [ProcEntry] {
    var out: [ProcEntry] = []
    var p = pid
    var seen: Set<Int> = []
    while p > 1, out.count < max, !seen.contains(p), let e = lookup(p) {
        seen.insert(p)
        out.append(e)
        p = e.ppid
    }
    return out
}

let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "crewshelf-shim", "crewshelf-hook"]

/// The Claude Code process a hook runs under, from the hook's parents (nearest first): the first one named
/// claude (the native build), else the first that is not a shell (`claude` run by node, a wrapper...).
public func claudeProcess(in parents: [ProcEntry]) -> ProcEntry? {
    if let c = parents.first(where: { $0.comm == "claude" || $0.comm.hasPrefix("claude") }) { return c }
    return parents.first { !shellNames.contains($0.comm) && !$0.comm.hasPrefix("-") }
}

/// The executable path of a process, or nil (gone, or not ours to read).
public func processPath(_ pid: Int) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

/// The `.app` bundle an executable path lies in ("/Applications/iTerm.app/Contents/MacOS/iTerm2" ->
/// "/Applications/iTerm.app"). The outermost bundle wins, so a helper inside an app counts as that app.
public func appBundlePath(executable: String) -> String? {
    guard let r = executable.range(of: ".app/Contents/") else { return nil }
    return String(executable[..<r.lowerBound]) + ".app"
}
