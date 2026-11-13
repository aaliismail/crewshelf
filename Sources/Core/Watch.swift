import Foundation

/// Identity of one wait: the same session waiting on a new prompt gets a new key.
public func blockKey(_ s: Session) -> String? {
    guard s.state == .blocked, !s.isFinished else { return nil }
    if let req = s.pendingKey { return [s.sessionId, "req", req].joined(separator: "|") }
    let since = s.since.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
    return [s.sessionId, s.needs ?? s.waitingFor ?? "", since].joined(separator: "|")
}

/// Decides which sessions to notify about: once per new prompt, never for prompts already open at launch.
public struct BlockWatcher {
    private var seen: Set<String> = []
    private var seeded = false

    public init() {}

    public mutating func newlyBlocked(_ sessions: [Session]) -> [Session] {
        let current = sessions.compactMap { s in blockKey(s).map { ($0, s) } }
        defer { seen.formUnion(current.map { $0.0 }); seeded = true }
        guard seeded else { return [] }
        return current.filter { !seen.contains($0.0) }.map { $0.1 }
    }
}

/// Sessions that left the roster stay on the shelf greyed out for a while.
public struct Departures {
    public private(set) var gone: [String: (session: Session, at: Date)] = [:]
    private var last: [String: Session] = [:]
    public var keep: TimeInterval = 300

    public init() {}

    public mutating func update(_ sessions: [Session], now: Date = Date()) -> [Session] {
        let ids = Set(sessions.map { $0.sessionId })
        for (id, s) in last where !ids.contains(id) && gone[id] == nil {
            var g = s
            g.rawState = "stopped"
            gone[id] = (g, now)
        }
        for id in ids { gone[id] = nil }
        gone = gone.filter { now.timeIntervalSince($0.value.at) < keep }
        last = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        return gone.values.map { $0.session }
    }
}
