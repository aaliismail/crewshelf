import Foundation

// What a hook reports about the terminal its session runs in. Compiled into the hook client too (Foundation only).

/// What the hook knows about the terminal of its session.
public struct TerminalEnv: Equatable {
    public var vars: [String: String]
    public var tty: String?          // "ttys003", the claude process's controlling terminal
    public var pid: Int?             // the claude process

    public init(vars: [String: String] = [:], tty: String? = nil, pid: Int? = nil) {
        self.vars = vars; self.tty = tty; self.pid = pid
    }

    public var isEmpty: Bool { vars.isEmpty && tty == nil && pid == nil }

    public var wire: [String: Any] {
        var d: [String: Any] = ["vars": vars]
        if let t = tty { d["tty"] = t }
        if let p = pid { d["pid"] = p }
        return d
    }

    /// From the wire. Unknown keys are dropped again, so the app keeps only the allowlist whatever a client sends.
    public init?(wire: Any?) {
        guard let d = wire as? [String: Any] else { return nil }
        let raw = d["vars"] as? [String: Any] ?? [:]
        var v: [String: String] = [:]
        for (k, x) in raw { if let s = x as? String { v[k] = s } }
        self.init(vars: captureTerminalVars(v), tty: (d["tty"] as? String).flatMap(cleanTty), pid: (d["pid"] as? NSNumber)?.intValue)
        if isEmpty { return nil }
    }
}

/// The only env variables the hook passes on: they say which terminal, window, tab or pane a session runs in.
/// Nothing else leaves the process (cmux, for one, puts socket passwords in the env).
public let terminalEnvKeys: [String] = [
    "TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "LC_TERMINAL", "TMUX", "TMUX_PANE",
    "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "__CFBundleIdentifier",
]

public func captureTerminalVars(_ env: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    for k in terminalEnvKeys {
        guard let v = env[k], !v.isEmpty, v.count <= 300, !v.contains("\n") else { continue }
        out[k] = v
    }
    return out
}

func cleanTty(_ s: String) -> String? {
    let t = s.hasPrefix("/dev/") ? String(s.dropFirst(5)) : s
    guard t.hasPrefix("tty"), t.count <= 16, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return t
}

/// The hook's view of its session: the allowlisted env, and the tty and pid of the Claude Code process it runs under.
public func captureTerminal(env: [String: String], parents: [ProcEntry]) -> TerminalEnv {
    let claude = claudeProcess(in: parents)
    let tty = claude?.tty ?? parents.first { $0.tty != nil }?.tty
    return TerminalEnv(vars: captureTerminalVars(env), tty: tty, pid: claude?.pid)
}
