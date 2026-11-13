import Foundation

/// Overlay hook state on the `claude agents` roster. Sessions with hook events are driven by them; sessions
/// without any stay as polled ("no plugin", Open only). Hook-only sessions (claude -p, or not listed yet) are added.
public func mergeHookSessions(_ roster: [Session], hooks: [HookSession], pending: [PendingRequest]) -> [Session] {
    let byId = Dictionary(hooks.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
    var firstPending: [String: PendingRequest] = [:]
    for p in pending where firstPending[p.sessionId] == nil { firstPending[p.sessionId] = p }

    func apply(_ base: Session, _ h: HookSession) -> Session {
        var s = base
        s.hooked = true
        if let t = h.terminal { s.terminal = t }
        if h.hasTerminal == false && s.kind != .background { s.headless = true }   // claude -p is listed like a tab
        s.hookSteps = h.steps.map { $0.step }
        s.doneText = h.lastMessage
        s.doneKey = h.doneAt.map { [h.sessionId, "stop", String(Int($0.timeIntervalSince1970 * 1000))].joined(separator: "|") }
        if s.transcriptPath == nil { s.transcriptPath = h.transcriptPath }
        if let p = firstPending[h.sessionId] {
            s.state = .blocked
            s.pendingKey = p.id
            s.waitingFor = p.kind == .question ? "your answer" : "approval"
            s.since = p.createdAt
        } else if h.inTerminal {
            s.state = .blocked
            s.waitingFor = "you in the terminal"
        } else if base.state == .blocked && !base.headless && (base.since ?? .distantPast) > h.lastEventAt {
            // Waiting on a prompt the plugin never saw (newer than the last hook event): keep the poll's view.
        } else {
            s.state = h.working ? .working : .idle
            s.waitingFor = nil
            s.since = h.working ? (h.steps.last?.step.timestamp ?? h.lastEventAt) : (h.doneAt ?? h.lastEventAt)
        }
        return s
    }

    var out: [Session] = roster.map { r in byId[r.sessionId].map { apply(r, $0) } ?? r }
    let listed = Set(roster.map { $0.sessionId })
    for h in hooks where !listed.contains(h.sessionId) {
        let name = (h.cwd as NSString).lastPathComponent
        var s = Session(sessionId: h.sessionId, name: name.isEmpty ? "claude" : name, cwd: h.cwd, kind: .interactive, state: .idle)
        s.headless = true
        s.startedAt = h.startedAt
        if h.endedAt != nil && firstPending[h.sessionId] == nil { s.rawState = "stopped" }   // drawn as departed
        out.append(apply(s, h))
    }
    return sortSessions(out)
}
