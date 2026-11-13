import Foundation

/// Flatten `cmux tree --all --json` into terminal surfaces.
public func parseCmuxTree(_ data: Data) -> [SurfaceRef] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let windows = root["windows"] as? [[String: Any]] else { return [] }
    var out: [SurfaceRef] = []
    for w in windows {
        let wref = w["ref"] as? String ?? ""
        for ws in (w["workspaces"] as? [[String: Any]]) ?? [] {
            let wsref = ws["ref"] as? String ?? ""
            for pane in (ws["panes"] as? [[String: Any]]) ?? [] {
                let pref = pane["ref"] as? String ?? ""
                for s in (pane["surfaces"] as? [[String: Any]]) ?? [] {
                    guard let sref = s["ref"] as? String else { continue }
                    out.append(SurfaceRef(windowRef: wref, workspaceRef: wsref, paneRef: pref, surfaceRef: sref,
                                          title: s["title"] as? String ?? "", tty: s["tty"] as? String))
                }
            }
        }
    }
    return out
}

/// Parse `ps -o pid=,tty= -p ...` into pid -> tty name ("ttys001").
public func parsePsTty(_ text: String) -> [Int: String] {
    var map: [Int: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
        let tty = String(parts[1])
        if tty == "??" || tty == "-" { continue }
        map[pid] = tty.hasPrefix("tty") ? tty : "tty" + tty
    }
    return map
}

/// From `ps -ax -o pid=,tty=,command=`: background agent id -> tty of a tab running `claude attach <id>`.
public func parseAttachTtys(_ text: String) -> [String: String] {
    var map: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, let ai = parts.firstIndex(of: "attach"), ai >= 3, ai + 1 < parts.count,
              parts[2].hasSuffix("claude") || parts[2].hasSuffix("/claude") else { continue }
        let tty = String(parts[1])
        guard tty != "??" else { continue }
        map[String(parts[ai + 1])] = tty.hasPrefix("tty") ? tty : "tty" + tty
    }
    return map
}

/// The cmux surface showing a session: an interactive tab by its own tty; a background agent by the tab that
/// has it parked (agent view) or the tab running `claude attach <id>`.
public func surfaceFor(session: Session, ttyByPid: [Int: String], attachTtys: [String: String] = [:],
                       surfaces: [SurfaceRef]) -> SurfaceRef? {
    var tty: String?
    switch session.kind {
    case .interactive:
        tty = session.pid.flatMap { ttyByPid[$0] }
    case .background:
        tty = session.hostPid.flatMap { ttyByPid[$0] }
            ?? session.shortId.flatMap { attachTtys[$0] } ?? attachTtys[session.sessionId]
    }
    guard let t = tty else { return nil }
    return surfaces.first { $0.tty == t }
}

public final class Cmux {
    public let bin: String
    public private(set) var denied = false
    public private(set) var lastError: String?

    public init?() {
        guard let b = firstExisting(["/Applications/cmux.app/Contents/Resources/bin/cmux",
                                     "\(home)/Applications/cmux.app/Contents/Resources/bin/cmux"]) else { return nil }
        bin = b
    }

    @discardableResult
    public func call(_ args: [String], timeout: TimeInterval = 4) -> RunResult {
        let r = run(bin, args, timeout: timeout)
        if r.ok {
            denied = false
            lastError = nil
        } else {
            let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = msg
            if msg.contains("Access denied") { denied = true }
        }
        return r
    }

    public func surfaces() -> [SurfaceRef] {
        let r = call(["tree", "--all", "--json"])
        return r.ok ? parseCmuxTree(Data(r.out.utf8)) : []
    }

    public static func focusCommands(_ s: SurfaceRef) -> [[String]] {
        [["focus-window", "--window", s.windowRef],
         ["select-workspace", "--workspace", s.workspaceRef, "--window", s.windowRef],
         ["focus-panel", "--panel", s.surfaceRef, "--workspace", s.workspaceRef, "--window", s.windowRef]]
    }

    public func focus(_ s: SurfaceRef) -> Bool {
        Cmux.focusCommands(s).allSatisfy { call($0).ok }
    }

    public static func attachCommand(claude: String, id: String, cwd: String) -> [String] {
        var args = ["new-surface", "--type", "terminal", "--focus", "true",
                    "--command", "\(shellQuote(claude)) attach \(shellQuote(id))"]
        if !cwd.isEmpty { args += ["--working-directory", cwd] }
        return args
    }
}
