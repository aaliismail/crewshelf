import Foundation

public struct Detail: Equatable {
    public var transcript: TranscriptSummary?
    public var note: String?                 // why the bubble cannot answer (no plugin)
    public init() {}
}

public struct ActionResult {
    public var ok: Bool
    public var message: String
    public static func fail(_ m: String) -> ActionResult { ActionResult(ok: false, message: m) }
}

public let cmuxBlockedNote = "cmux only lets its own tabs use its socket. To let Crewshelf open tabs, set cmux Settings > Automation > Socket control to \"Automation mode\"."

public let noPluginNote = "No plugin in this session, so Crewshelf can't answer it. Open answers it in the terminal."

public final class Engine {
    public let claudeDir: String
    public let claudeBin: String?
    public let cmux: Cmux?
    public private(set) var roster: [RosterEntry] = []
    public private(set) var rosterError: String?
    public var hidden = HiddenStore()
    private var lastRosterAt = Date.distantPast
    private var lastPids: Set<Int> = []
    private let hiddenPath: String
    public var rosterInterval: TimeInterval = 10
    /// CREWSHELF_NO_ROSTER=1: hook sessions only (a test instance that must not show or touch the real agents).
    public var rosterOff = ProcessInfo.processInfo.environment["CREWSHELF_NO_ROSTER"] == "1"
    private var focusCache: (at: Date, tty: String?)?
    /// Tests and demo mode: run Open's steps here instead of for real.
    public var stepRunner: ((OpenStep) -> (ok: Bool, detail: String))?

    public init(claudeDir: String = home + "/.claude") {
        self.claudeDir = claudeDir
        claudeBin = firstExisting(["/opt/homebrew/bin/claude", "\(home)/.local/bin/claude", "/usr/local/bin/claude",
                                   "\(home)/.claude/local/claude"])
        cmux = Cmux()
        hiddenPath = crewshelfSupportDir() + "/hidden.json"     // the folder is made on first save, not here
        if let d = FileManager.default.contents(atPath: hiddenPath),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: String] {
            hidden = HiddenStore(map: m)
        }
    }

    // MARK: reading

    func pidAlive(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 || errno == EPERM }

    public func loadSessionFiles() -> [Int: SessionFile] {
        let dir = claudeDir + "/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [Int: SessionFile] = [:]
        for n in names where n.hasSuffix(".json") {
            guard let d = FileManager.default.contents(atPath: "\(dir)/\(n)"), let f = parseSessionFile(d),
                  pidAlive(f.pid) else { continue }
            out[f.pid] = f
        }
        return out
    }

    public func loadJob(_ id: String) -> (JobState?, Date?) {
        let dir = "\(claudeDir)/jobs/\(id)"
        guard let d = FileManager.default.contents(atPath: dir + "/state.json"), let j = parseJobState(d) else {
            return (nil, nil)
        }
        let since = j.state.flatMap { st in
            readTail(path: dir + "/timeline.jsonl", maxBytes: 32_000).flatMap { stateSince(timelineTail: $0, state: st) }
        }
        return (j, since)
    }

    public func refreshRoster() {
        guard let bin = claudeBin else { rosterError = "claude CLI not found"; return }
        let r = run(bin, ["agents", "--json"], timeout: 10)
        if r.ok {
            roster = parseRoster(Data(r.out.utf8))
            rosterError = nil
        } else {
            rosterError = r.err.isEmpty ? "claude agents failed" : r.err
        }
        lastRosterAt = Date()
    }

    /// One poll: cheap file reads every time, the `claude agents` roster only every `rosterInterval`
    /// or when a Claude process starts or exits.
    public func snapshot() -> [Session] {
        if rosterOff { return [] }
        let files = loadSessionFiles()
        let pids = Set(files.keys)
        if pids != lastPids || Date().timeIntervalSince(lastRosterAt) > rosterInterval { refreshRoster() }
        lastPids = pids
        var jobs: [String: JobState] = [:], since: [String: Date] = [:]
        for e in roster where e.kind == .background {
            guard let id = e.shortId else { continue }
            let (j, s) = loadJob(id)
            jobs[id] = j
            since[id] = s
        }
        let sessions = buildSessions(roster: roster, sessionFiles: files, jobs: jobs, jobSince: since)
        if hidden.prune(sessions) { saveHidden() }
        return sessions
    }

    func saveHidden() {
        if let d = try? JSONSerialization.data(withJSONObject: hidden.map) {
            try? FileManager.default.createDirectory(atPath: (hiddenPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: hiddenPath, contents: d)
        }
    }

    /// Agents whose own terminal tab has keyboard focus right now, so alerting them is pointless. Best effort:
    /// cmux only (its tree marks the focused tab and its tty), and only when cmux is the frontmost app.
    /// Any other terminal, or cmux refusing Crewshelf its socket, gives none (alerts as usual). Cached 2 s.
    public func focusedSessions(_ sessions: [Session], frontmost: String?) -> Set<String> {
        guard frontmost == "com.cmuxterm.app", let cmux = cmux else { return [] }
        let tty: String?
        if let c = focusCache, Date().timeIntervalSince(c.at) < 2 { tty = c.tty }
        else {
            let r = cmux.call(["tree", "--all", "--json"])
            tty = r.ok ? focusedTty(cmuxTree: Data(r.out.utf8)) : nil
            focusCache = (Date(), tty)
        }
        guard let t = tty else { return [] }
        let pids = sessions.compactMap { $0.kind == .interactive ? $0.pid : $0.hostPid }
        guard !pids.isEmpty else { return [] }
        let ttys = parsePsTty(run("/bin/ps", ["-o", "pid=,tty=", "-p", pids.map(String.init).joined(separator: ",")], timeout: 3).out)
        return Set(sessions.filter { s in (s.kind == .interactive ? s.pid : s.hostPid).flatMap { ttys[$0] } == t }.map { $0.sessionId })
    }

    public func surface(for s: Session) -> SurfaceRef? {
        guard let cmux = cmux else { return nil }
        var ttys: [Int: String] = [:], attach: [String: String] = [:]
        if s.kind == .interactive || s.hostPid != nil {
            guard let p = s.kind == .interactive ? s.pid : s.hostPid else { return nil }
            ttys = parsePsTty(run("/bin/ps", ["-o", "pid=,tty=", "-p", String(p)], timeout: 3).out)
        }
        if s.kind == .background && ttys.isEmpty {
            attach = parseAttachTtys(run("/bin/ps", ["-ax", "-o", "pid=,tty=,command="], timeout: 3).out)
        }
        guard !ttys.isEmpty || !attach.isEmpty else { return nil }
        return surfaceFor(session: s, ttyByPid: ttys, attachTtys: attach, surfaces: cmux.surfaces())
    }

    private var transcriptCache: [String: (size: UInt64, summary: TranscriptSummary)] = [:]

    /// Parsed transcript tail, re-read only when the file grows.
    public func transcript(for s: Session, limit: Int = 15) -> TranscriptSummary? {
        guard let path = findTranscript(projectsDir: claudeDir + "/projects", session: s) else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let key = "\(path)#\(limit)"
        if let c = transcriptCache[key], c.size == size { return c.summary }
        guard let t = loadTranscript(path: path, limit: limit) else { return nil }
        if transcriptCache.count > 40 { transcriptCache.removeAll() }
        transcriptCache[key] = (size, t)
        return t
    }

    /// Everything a bubble needs besides the hook request itself. Hooked sessions use hook steps, others the transcript.
    public func detail(for s: Session, limit: Int = 15) -> Detail {
        var d = Detail()
        if s.hooked && !s.hookSteps.isEmpty {
            d.transcript = TranscriptSummary(steps: Array(s.hookSteps.suffix(limit)), lastText: s.doneText, lastTextAt: nil)
        } else {
            d.transcript = transcript(for: s, limit: limit)
        }
        if s.state == .blocked && s.pendingKey == nil {
            d.note = s.hooked ? "Waiting in the terminal. Open goes there." : noPluginNote
        }
        return d
    }

    // MARK: actions

    /// Background: `claude stop <id>` (the conversation is kept). Interactive: hide until its state changes.
    public func done(_ s: Session) -> ActionResult {
        if s.kind == .interactive {
            hidden.hide(s)
            saveHidden()
            return ActionResult(ok: true, message: "Hidden until its state changes.")
        }
        guard let id = s.shortId, let claude = claudeBin else { return .fail("No background id.") }
        let r = run(claude, ["stop", id], timeout: 15)
        lastRosterAt = .distantPast
        return r.ok ? ActionResult(ok: true, message: "Stopped \(id). Conversation kept.")
                    : .fail((r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func find(_ key: String, in sessions: [Session]) -> Session? {
        sessions.first { $0.sessionId == key || $0.shortId == key || $0.sessionId.hasPrefix(key) || $0.name == key }
    }
}
