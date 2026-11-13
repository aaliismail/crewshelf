import Foundation

func ago(_ d: Date?) -> String { d.map { formatDuration(Date().timeIntervalSince($0)) } ?? "?" }

func indent(_ s: String, _ pad: String = "      ") -> String {
    s.components(separatedBy: "\n").map { pad + $0 }.joined(separator: "\n")
}

/// Printed first by `--dump`: it reads this Mac's ~/.claude itself (never the running app, never a demo).
public let dumpNotice = "# read from ~/.claude on this Mac: real session names, folders and commands. Check it before you share it."

/// `Crewshelf --dump [--steps N]`: the sessions Crewshelf finds in ~/.claude, as text.
public func dump(engine: Engine, steps: Int = 15) -> String {
    let sessions = engine.snapshot()
    var out: [String] = [dumpNotice]
    let c = countStates(sessions)
    out.append("crewshelf  working \(c[.working] ?? 0)  blocked \(c[.blocked] ?? 0)  idle \(c[.idle] ?? 0)")
    if let e = engine.rosterError { out.append("roster error: \(e)") }
    out.append("")
    for s in sessions {
        let id = s.shortId ?? String(s.sessionId.prefix(8))
        let raw = [s.rawStatus.map { "status=\($0)" }, s.rawState.map { "job=\($0)" }].compactMap { $0 }.joined(separator: " ")
        let hiddenTag = engine.hidden.isHidden(s) ? "  [hidden]" : ""
        out.append("[\(s.state.rawValue)] \(s.name)  ·  \(s.project)  ·  \(s.kind.rawValue) \(id)  ·  \(ago(s.since)) in state  (\(raw))\(hiddenTag)")
        let d = engine.detail(for: s, limit: steps)
        if s.hooked { out.append("    plugin: yes\(s.pendingKey.map { "  pending request \($0)" } ?? "")") }
        if let w = s.waitingFor { out.append("    waiting for: \(w)") }
        if let n = d.note { out.append("    note: \(n)") }
        if let t = d.transcript {
            for st in t.steps {
                let flag = st.pending ? " (pending)" : st.isError ? " (error)" : ""
                out.append("    \(ago(st.timestamp).padding(toLength: 4, withPad: " ", startingAt: 0)) \(st.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(st.summary)\(flag)")
            }
            if let lt = t.lastText {
                out.append("    last text (\(ago(t.lastTextAt)) ago): \(oneLine(lt, max: 240))")
            }
        } else {
            out.append("    (no transcript found)")
        }
        out.append("")
    }
    return out.joined(separator: "\n")
}
