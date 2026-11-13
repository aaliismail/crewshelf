import Foundation

/// One entry of `claude agents --json`.
public struct RosterEntry: Equatable {
    public var sessionId: String
    public var shortId: String?
    public var cwd: String
    public var kind: SessionKind
    public var name: String
    public var startedAt: Date?
    public var state: String?
    public var status: String?
    public var pid: Int?
}

/// `~/.claude/sessions/<pid>.json`, written by every live Claude Code process.
public struct SessionFile: Equatable {
    public var pid: Int
    public var sessionId: String?
    public var status: String?
    public var statusUpdatedAt: Date?
    public var waitingFor: String?
    public var parkedJobId: String?
    public var jobId: String?
}

/// `~/.claude/jobs/<id>/state.json`, written for every background agent.
public struct JobState: Equatable {
    public var state: String?
    public var detail: String?
    public var needs: String?
    public var suggestedReply: String?
    public var transcriptPath: String?
    public var updatedAt: Date?
}

func msDate(_ v: Any?) -> Date? {
    guard let n = v as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000)
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

public func isoDate(_ v: Any?) -> Date? {
    guard let s = v as? String else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

func intValue(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

public func parseRoster(_ data: Data) -> [RosterEntry] {
    guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
    return arr.compactMap { d in
        guard let sid = d["sessionId"] as? String else { return nil }
        let kind: SessionKind = (d["kind"] as? String) == "interactive" ? .interactive : .background
        let cwd = d["cwd"] as? String ?? ""
        let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent
        return RosterEntry(sessionId: sid, shortId: d["id"] as? String, cwd: cwd, kind: kind, name: name,
                           startedAt: msDate(d["startedAt"]), state: d["state"] as? String,
                           status: d["status"] as? String, pid: intValue(d["pid"]))
    }
}

public func parseSessionFile(_ data: Data) -> SessionFile? {
    guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pid = intValue(d["pid"]) else { return nil }
    return SessionFile(pid: pid, sessionId: d["sessionId"] as? String, status: d["status"] as? String,
                       statusUpdatedAt: msDate(d["statusUpdatedAt"]), waitingFor: d["waitingFor"] as? String,
                       parkedJobId: d["parkedJobId"] as? String, jobId: d["jobId"] as? String)
}

public func parseJobState(_ data: Data) -> JobState? {
    guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return JobState(state: d["state"] as? String, detail: d["detail"] as? String, needs: d["needs"] as? String,
                    suggestedReply: d["suggestedReply"] as? String, transcriptPath: d["linkScanPath"] as? String,
                    updatedAt: isoDate(d["updatedAt"]))
}

/// When the job entered its current state: the start of the trailing run of same-state timeline entries.
public func stateSince(timelineTail: String, state: String) -> Date? {
    var since: Date?
    for line in timelineTail.split(separator: "\n").reversed() {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        guard (d["state"] as? String) == state else { break }
        since = isoDate(d["at"]) ?? since
    }
    return since
}

public func mapState(kind: SessionKind, status: String?, jobState: String?) -> HState {
    if kind == .interactive {
        switch status {
        case "waiting": return .blocked
        case "busy": return .working
        default: return .idle          // idle, and "shell" (turn over, a background shell still running)
        }
    }
    switch jobState {
    case "blocked", "waiting", "needs_input": return .blocked
    case "working", "running", "busy": return .working
    default: break
    }
    switch status {
    case "waiting": return .blocked
    case "busy": return .working
    default: return .idle
    }
}

/// Merge the roster with the per-process and per-job files into what the widget shows.
public func buildSessions(roster: [RosterEntry], sessionFiles: [Int: SessionFile], jobs: [String: JobState],
                          jobSince: [String: Date]) -> [Session] {
    let hostByJob = Dictionary(sessionFiles.values.compactMap { f in f.parkedJobId.map { ($0, f.pid) } },
                               uniquingKeysWith: { a, _ in a })
    let sessions: [Session] = roster.map { e in
        var s = Session(sessionId: e.sessionId, name: e.name, cwd: e.cwd, kind: e.kind, state: .idle)
        s.shortId = e.shortId
        s.pid = e.pid
        s.rawStatus = e.status
        s.rawState = e.state
        s.since = e.startedAt
        s.startedAt = e.startedAt
        if let pid = e.pid, let f = sessionFiles[pid], f.sessionId == nil || f.sessionId == e.sessionId {
            s.rawStatus = f.status ?? s.rawStatus
            s.waitingFor = f.waitingFor
            if e.kind == .interactive { s.since = f.statusUpdatedAt ?? s.since }
        }
        if e.kind == .background, let id = e.shortId {
            if let j = jobs[id] {
                s.rawState = j.state ?? s.rawState
                s.needs = j.needs
                s.suggestedReply = j.suggestedReply
                s.detail = j.detail
                s.transcriptPath = j.transcriptPath
                s.since = jobSince[id] ?? j.updatedAt ?? s.since
            }
            s.hostPid = hostByJob[id]
        }
        s.state = mapState(kind: s.kind, status: s.rawStatus, jobState: s.rawState)
        if s.state != .blocked { s.waitingFor = nil }
        return s
    }
    return sortSessions(sessions)
}

public func sortSessions(_ list: [Session]) -> [Session] {
    list.sorted { a, b in
        if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
        let ta = a.since ?? .distantFuture, tb = b.since ?? .distantFuture
        if ta != tb { return ta < tb }
        return a.name < b.name
    }
}

public func countStates(_ sessions: [Session]) -> [HState: Int] {
    var c: [HState: Int] = [.working: 0, .blocked: 0, .idle: 0]
    for s in sessions { c[s.state, default: 0] += 1 }
    return c
}

/// Interactive tabs the user marked Done. A tab stays hidden until its state changes.
public struct HiddenStore: Equatable {
    public var map: [String: String] = [:]   // sessionId -> state when hidden

    public init(map: [String: String] = [:]) { self.map = map }

    public func isHidden(_ s: Session) -> Bool { map[s.sessionId] == s.state.rawValue }

    public mutating func hide(_ s: Session) { map[s.sessionId] = s.state.rawValue }

    /// Drop entries whose session changed state or disappeared. Returns true if anything changed.
    @discardableResult
    public mutating func prune(_ sessions: [Session]) -> Bool {
        let live = Dictionary(sessions.map { ($0.sessionId, $0.state.rawValue) }, uniquingKeysWith: { a, _ in a })
        let next = map.filter { live[$0.key] == $0.value }
        defer { map = next }
        return next != map
    }

    public func visible(_ sessions: [Session]) -> [Session] { sessions.filter { !isHidden($0) } }
}
