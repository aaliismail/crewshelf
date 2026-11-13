import Foundation

// What the plugin's hooks tell the app, and the one place a decision is made (buttons and `--ctl` alike).

public struct HookOption: Equatable {
    public var label: String
    public var description: String?
}

public struct HookQuestion: Equatable {
    public var question: String
    public var header: String?
    public var options: [HookOption]
    public var multiSelect: Bool
}

public func parseQuestions(_ toolInput: [String: Any]) -> [HookQuestion] {
    ((toolInput["questions"] as? [[String: Any]]) ?? []).compactMap { q in
        guard let text = q["question"] as? String else { return nil }
        let opts = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o in
            (o["label"] as? String).map { HookOption(label: $0, description: o["description"] as? String) }
        }
        return HookQuestion(question: text, header: q["header"] as? String, options: opts,
                            multiSelect: (q["multiSelect"] as? Bool) ?? false)
    }
}

/// Answer text for one question from the picked labels and the "Other" field. Multi-select joins with ", ".
public func answerText(picked: [String], other: String, multiSelect: Bool) -> String {
    let o = other.trimmingCharacters(in: .whitespacesAndNewlines)
    if !multiSelect { return o.isEmpty ? (picked.first ?? "") : o }
    return (picked + (o.isEmpty ? [] : [o])).joined(separator: ", ")
}

/// What a permission bubble shows: the tool, one line of context, warnings, and the whole input (a diff for
/// edits). Approve sends the whole tool_input back, so nothing in it is ever left out: keys the tool's own layout
/// does not use are listed after it. Input too long to show in full is flagged, and then Approve is refused.
public struct PermissionPreview: Equatable {
    public enum Style: String { case plain, diff, code }
    public var title: String
    public var subtitle: String?
    public var body: String
    public var style: Style
    public var warnings: [String] = []
    public var tooLong = false
    public var lineCount: Int { body.isEmpty ? 0 : body.components(separatedBy: "\n").count }
}

/// Largest input a bubble renders in full. Beyond it the bubble shows the start, says so, and refuses Approve.
public let previewMaxLines = 4000
public let previewMaxChars = 200_000
/// The subtitle line (a file path, a URL, a Bash description) is shown in full up to this many wrapped rows.
public let subtitleMaxRows = 6
let subtitleColumns = 44
/// Tools whose subtitle is the thing the call acts on.
let subtitleTarget = ["Edit": "Path", "MultiEdit": "Path", "Write": "Path", "NotebookEdit": "Path", "WebFetch": "URL"]
public let sandboxWarning = "Runs OUTSIDE the sandbox"

/// Rows a text takes when wrapped at `columns` characters (each line at least one).
func wrappedRows(_ text: String, columns: Int = subtitleColumns) -> Int {
    text.components(separatedBy: "\n").reduce(0) { $0 + max(1, ($1.count + columns - 1) / columns) }
}

/// The start of `text` that fits in `rows` wrapped rows, ending in "…".
func clipRows(_ text: String, rows: Int, columns: Int = subtitleColumns) -> String {
    var out: [String] = [], left = rows
    for line in text.components(separatedBy: "\n") {
        let need = max(1, (line.count + columns - 1) / columns)
        if need > left { out.append(String(line.prefix(max(0, left * columns - 1)))); break }
        out.append(line)
        left -= need
        if left == 0 { break }
    }
    var clipped = out.joined(separator: "\n")
    while wrappedRows(clipped + "…", columns: columns) > rows, !clipped.isEmpty { clipped.removeLast() }
    return clipped + "…"
}

func diffLines(old: String, new: String) -> String {
    func trim(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
    let (old, new) = (trim(old), trim(new))
    let o = old.isEmpty ? [] : old.components(separatedBy: "\n").map { "- " + $0 }
    let n = new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+ " + $0 }
    return (o + n).joined(separator: "\n")
}

func prettyJSON(_ v: Any) -> String {
    if let s = v as? String { return s }
    if JSONSerialization.isValidJSONObject(v),
       let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        return String(decoding: d, as: UTF8.self)
    }
    return canonicalJSON([v]).map { String($0.dropFirst().dropLast()) } ?? "\(v)"
}

public func permissionPreview(toolName: String, input: [String: Any]) -> PermissionPreview {
    func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    let name = displayToolName(toolName)
    var used: Set<String> = []
    var p: PermissionPreview
    switch toolName {
    case "Bash", "PowerShell", "Monitor":
        used = ["command", "description"]
        p = PermissionPreview(title: name, subtitle: str("description"), body: str("command") ?? "", style: .code)
    case "Edit":
        used = ["file_path", "old_string", "new_string", "replace_all"]
        var d = diffLines(old: str("old_string") ?? "", new: str("new_string") ?? "")
        if (input["replace_all"] as? Bool) == true { d = "(every occurrence)\n" + d }
        p = PermissionPreview(title: name, subtitle: str("file_path").map { shortPath($0) }, body: d, style: .diff)
    case "MultiEdit":
        used = ["file_path", "edits"]
        let edits = (input["edits"] as? [[String: Any]]) ?? []
        let d = edits.map { e -> String in
            var one = diffLines(old: e["old_string"] as? String ?? "", new: e["new_string"] as? String ?? "")
            if (e["replace_all"] as? Bool) == true { one = "(every occurrence)\n" + one }
            return one
        }.joined(separator: "\n···\n")
        p = PermissionPreview(title: name, subtitle: str("file_path").map { shortPath($0) }, body: d, style: .diff)
    case "Write":
        used = ["file_path", "content"]
        p = PermissionPreview(title: name, subtitle: str("file_path").map { shortPath($0) },
                              body: diffLines(old: "", new: str("content") ?? ""), style: .diff)
    case "NotebookEdit":
        used = ["notebook_path", "new_source"]
        p = PermissionPreview(title: name, subtitle: str("notebook_path").map { shortPath($0) },
                              body: diffLines(old: "", new: str("new_source") ?? ""), style: .diff)
    case "WebFetch":
        used = ["url", "prompt"]
        p = PermissionPreview(title: name, subtitle: str("url"), body: str("prompt") ?? "", style: .plain)
    default:
        used = Set(input.keys)
        p = PermissionPreview(title: name, subtitle: nil, body: input.isEmpty ? "" : prettyJSON(input), style: .code)
    }
    // Every other key, so what is approved is what is shown (e.g. Bash's timeout, run_in_background).
    let rest = input.keys.filter { !used.contains($0) }.sorted()
    if !rest.isEmpty {
        let lines = rest.map { "\($0): \(prettyJSON(input[$0]!))" }.joined(separator: "\n")
        p.body += (p.body.isEmpty ? "" : "\n\n") + "· other input\n" + lines
    }
    if (input["dangerouslyDisableSandbox"] as? Bool) == true { p.warnings.append(sandboxWarning) }
    if (input["run_in_background"] as? Bool) == true { p.warnings.append("Runs in the background") }
    if (input["replace_all"] as? Bool) == true { p.warnings.append("Replaces every occurrence") }
    // The bubble shows the subtitle in full, so a long one is cut here. When it is what the call acts on (a file
    // path, a URL), a cut one can't be approved: the part you can't see could point anywhere.
    if let sub = p.subtitle, wrappedRows(sub) > subtitleMaxRows {
        p.subtitle = clipRows(sub, rows: subtitleMaxRows)
        if let target = subtitleTarget[toolName] {
            p.tooLong = true
            p.warnings.append("\(target) too long to show in full: Approve is off")
        }
    }
    let lines = p.body.components(separatedBy: "\n")
    if lines.count > previewMaxLines || p.body.count > previewMaxChars {
        p.tooLong = true
        var head = lines.prefix(previewMaxLines).joined(separator: "\n")
        if head.count > previewMaxChars { head = String(head.prefix(previewMaxChars)) }
        p.body = head + "\n… too long to show in full (\(lines.count) lines, \(p.body.count) characters)"
        p.warnings.append("Too long to show in full: Approve is off")
    }
    return p
}

public struct PendingRequest: Equatable {
    public enum Kind: String { case permission, question }
    public var id: String
    public var sessionId: String
    public var kind: Kind
    public var event: String
    public var toolName: String
    public var cwd: String
    public var permissionMode: String?
    public var createdAt: Date
    public var deadline: Date
    public var preview: PermissionPreview
    public var questions: [HookQuestion]
    public var stepId: String?             // the tool_use_id of the call this request belongs to, when known
    public var inputFP: String = ""         // fingerprint of tool_input, to match the PostToolUse of this call
    public var hasTerminal = false          // the session shows its own prompt, so "Answer in terminal" is real
    public var agentId: String?             // set when the call is inside a subagent or teammate

    public var summary: String {
        switch kind {
        case .question: return questions.first?.question ?? "A question"
        case .permission: return "\(preview.title): \(oneLine(preview.subtitle ?? preview.body, max: 160))"
        }
    }
}

public struct HookStepMark: Equatable {
    public var step: Step
    public var fingerprint: String
}

/// Live state of one session, built only from hook events.
public struct HookSession: Equatable {
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    public var permissionMode: String?
    public var working = false
    public var startedAt: Date
    public var lastEventAt: Date
    public var steps: [HookStepMark] = []
    public var lastMessage: String?
    public var doneAt: Date?
    public var endedAt: Date?
    public var inTerminal = false          // "Answer in terminal" was chosen and nothing has happened since
    public var hasTerminal: Bool?          // from the hook env: an interactive tab (true) or -p / background (false)
    public var lastPromptAt: Date?
    public var terminal: TerminalEnv?      // the terminal its hooks reported (allowlisted env, tty, claude pid)
}

public enum DecideError: String, Error {
    case unknown = "No such request (already answered, released, or expired)."
    case expired = "Too late: the hook's deadline passed. Nothing was approved."
    case wrongKind = "That answer does not fit this request."
    case badAnswers = "Every question needs an answer."
    case hookGone = "The agent stopped waiting. Nothing was sent."
    case answeredElsewhere = "Already answered in the terminal. Nothing was sent."
    case tooLong = "Too long to show in full, so it can't be approved here. Deny, or answer in the terminal."
    case controlOff = "Test control is off. Start Crewshelf with CREWSHELF_TEST_CONTROL=1 to decide through --ctl."
}

/// A request's buttons work only after it has been on screen for `delay` since it last came on screen, so a click
/// aimed at one request can never land on another that was just swapped into the same place, even one that was
/// shown before (a double-click on Approve answers one request, never the one that opens after it).
public struct ArmGate {
    public var delay: TimeInterval
    private var shown: [String: Date] = [:]
    public init(delay: TimeInterval = 0.6) { self.delay = delay }
    /// Record that a request came on screen, now. Every appearance restarts the delay.
    public mutating func see(_ id: String, now: Date = Date()) {
        if shown.count > 200 { shown = shown.filter { now.timeIntervalSince($0.value) < 3600 } }
        shown[id] = now
    }
    public func armed(_ id: String, now: Date = Date()) -> Bool {
        guard let t = shown[id] else { return false }
        return now.timeIntervalSince(t) >= delay
    }
}

public final class HookCenter {
    private let lock = NSLock()
    private var sessions: [String: HookSession] = [:]
    private var pending: [String: (req: PendingRequest, conn: HookConnection)] = [:]
    private var scan: [String: (path: String, offset: UInt64)] = [:]      // transcript read position per session
    private var settledElsewhere: [String: Date] = [:]   // request ids released because the call moved on
    private var handedOff: [String: Date] = [:]          // "session|tool_use_id" handed to the terminal
    public var onChange: () -> Void = {}
    /// UI operations for `--ctl` (e.g. "tap": the same function a click on a character calls). Set by the app.
    public var uiControl: ([String: Any]) -> [String: Any]? = { _ in nil }
    /// `--ctl decide`, `answer`, `tap` and `open` work only when this is on (the app sets it from CREWSHELF_TEST_CONTROL=1).
    public var allowControlDecisions = false
    public var maxSteps = 15
    /// How long before the hook gives up the app stops taking decisions, so a decision it accepts always reaches
    /// the hook in time (never "Approved." in the bubble with nothing applied).
    public var decisionMargin: TimeInterval = 2
    /// Demo mode: only `--ctl` requests are served; hook events and decision requests are closed unread.
    public var controlOnly = false
    private var eventCount = 0
    /// Hook events and decision requests received since launch (the first-run bubble goes once this is above 0).
    public var eventsSeen: Int { lock.lock(); defer { lock.unlock() }; return eventCount }

    public init() {}

    public func snapshot() -> (sessions: [HookSession], pending: [PendingRequest]) {
        lock.lock()
        defer { lock.unlock() }
        return (Array(sessions.values), pending.values.map { $0.req }.sorted { $0.createdAt < $1.createdAt })
    }

    // MARK: events

    public func handleEvent(_ event: String, input: [String: Any], fingerprint: String? = nil, terminal: Bool? = nil,
                            term: TerminalEnv? = nil, now: Date = Date()) {
        guard let sid = input["session_id"] as? String, !sid.isEmpty else { return }
        let agent = input["agent_id"] as? String
        lock.lock()
        eventCount += 1
        var s = touchLocked(sid, input, terminal: terminal, term: term, now: now)
        if s.endedAt != nil && event != "SessionEnd" { s.endedAt = nil }
        if event != "Notification" { s.inTerminal = false }
        switch event {
        case "SessionStart":
            s.working = false
        case "UserPromptSubmit":
            s.working = true
            s.doneAt = nil
            s.lastPromptAt = now
        case "PreToolUse":
            s.working = true
            s.doneAt = nil
            addStepLocked(&s, input, fingerprint: fingerprint, now: now)
        case "PostToolUse", "PostToolUseFailure":
            s.working = true
            if let id = input["tool_use_id"] as? String, let i = s.steps.firstIndex(where: { $0.step.id == id }) {
                s.steps[i].step.pending = false
                s.steps[i].step.isError = event == "PostToolUseFailure"
            }
        case "Stop":
            s.working = false
            s.doneAt = now
            s.lastMessage = (input["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.lastMessage
            for i in s.steps.indices { s.steps[i].step.pending = false }
        case "StopFailure":
            s.working = false          // the turn ended on an API error: no Done, no check
            for i in s.steps.indices { s.steps[i].step.pending = false }
        case "Notification" where (input["notification_type"] as? String) == "idle_prompt":
            // Claude finished about a minute ago and nobody has typed: nothing is running or waiting any more.
            s.working = false
            s.inTerminal = false
            for i in s.steps.indices { s.steps[i].step.pending = false }
        case "SessionEnd":
            s.working = false
            s.endedAt = now
        default:
            break     // Notification, SubagentStop, PostToolBatch: liveness only
        }
        sessions[sid] = s
        // A request still held after its call has moved on was answered somewhere else: the terminal dialog runs
        // alongside the hook and Claude Code does not stop the hook. Release it with no output. Only requests of
        // the same agent: a subagent's request stays while the main agent's turn goes on, and the other way round.
        var stale: [String] = []
        let mine = pending.filter { $0.value.req.sessionId == sid }
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            let fp = fingerprint ?? inputFingerprint(input["tool_input"])
            let tool = input["tool_name"] as? String
            let tuid = input["tool_use_id"] as? String
            stale = mine.filter { _, p in
                if let t = tuid, let step = p.req.stepId { return t == step }
                return p.req.toolName == tool && p.req.inputFP == fp && p.req.agentId == agent
            }.map { $0.key }
        case "PostToolBatch":
            stale = mine.filter { $0.value.req.agentId == agent }.map { $0.key }
        case "Stop", "StopFailure", "UserPromptSubmit":
            stale = mine.filter { $0.value.req.agentId == nil }.map { $0.key }
        case "Notification" where (input["notification_type"] as? String) == "idle_prompt":
            stale = mine.filter { $0.value.req.agentId == nil }.map { $0.key }
        case "SubagentStop":
            stale = agent == nil ? [] : mine.filter { $0.value.req.agentId == agent }.map { $0.key }
        case "SessionEnd":
            stale = Array(mine.keys)
        default:
            break
        }
        let conns = settleLocked(stale, now: now)
        lock.unlock()
        conns.forEach { $0.release() }
        onChange()
    }

    /// The session record, created on first sight, with the fields every hook input carries.
    private func touchLocked(_ sid: String, _ input: [String: Any], terminal: Bool?, term: TerminalEnv? = nil,
                             now: Date) -> HookSession {
        var s = sessions[sid] ?? HookSession(sessionId: sid, cwd: input["cwd"] as? String ?? "", startedAt: now, lastEventAt: now)
        s.lastEventAt = now
        if let t = term, !t.isEmpty { s.terminal = t }
        if let c = input["cwd"] as? String, !c.isEmpty { s.cwd = c }
        if let m = input["permission_mode"] as? String { s.permissionMode = m }
        if let t = terminal { s.hasTerminal = t }
        if let t = input["transcript_path"] as? String, !t.isEmpty {
            s.transcriptPath = t
            if scan[sid]?.path != t { scan[sid] = (t, fileSize(t)) }     // only what is written from now on
        }
        return s
    }

    private func addStepLocked(_ s: inout HookSession, _ input: [String: Any], fingerprint: String?, now: Date) {
        let tool = input["tool_name"] as? String ?? "?"
        let ti = input["tool_input"] as? [String: Any] ?? [:]
        let id = input["tool_use_id"] as? String ?? UUID().uuidString
        let fp = fingerprint ?? inputFingerprint(ti)
        if !s.steps.contains(where: { $0.step.id == id }) {
            s.steps.append(HookStepMark(step: Step(id: id, name: displayToolName(tool), summary: summarizeTool(name: tool, input: ti),
                                                   timestamp: now, isError: false, pending: true), fingerprint: fp))
            if s.steps.count > maxSteps { s.steps.removeFirst(s.steps.count - maxSteps) }
        }
        // A PermissionRequest whose PreToolUse event was handled after it (two socket threads) gets its step now.
        for (k, p) in pending where p.req.sessionId == s.sessionId && p.req.stepId == nil && p.req.toolName == tool
            && p.req.inputFP == fp && p.req.agentId == (input["agent_id"] as? String) {
            pending[k]?.req.stepId = id
        }
    }

    /// Drop requests from the table and remember that they were settled elsewhere. Returns their connections.
    private func settleLocked(_ ids: [String], now: Date) -> [HookConnection] {
        if settledElsewhere.count > 500 { settledElsewhere = settledElsewhere.filter { now.timeIntervalSince($0.value) < 3600 } }
        return ids.compactMap { id in
            guard let p = pending.removeValue(forKey: id) else { return nil }
            settledElsewhere[id] = now
            return p.conn
        }
    }

    /// The PreToolUse step a PermissionRequest belongs to: the latest unfinished step in the same session with
    /// the same tool and the same input (PermissionRequest has no tool_use_id).
    public func correlate(sessionId: String, toolName: String, fingerprint: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return correlateLocked(sessionId: sessionId, toolName: toolName, fingerprint: fingerprint)
    }

    private func correlateLocked(sessionId: String, toolName: String, fingerprint: String) -> String? {
        sessions[sessionId]?.steps.last { $0.step.pending && $0.step.name == displayToolName(toolName) && $0.fingerprint == fingerprint }?.step.id
    }

    // MARK: the transcript: how a call answered in the terminal is noticed

    /// True while some session has something that only its transcript can settle.
    public var needsReconcile: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty || sessions.values.contains { $0.inTerminal || ($0.working && $0.endedAt == nil) }
    }

    /// Read what each watched session's transcript gained since last time. A tool_result for a held request's call
    /// means it was answered in the terminal (allowed or denied): the request is released with no output and its
    /// step finished. "[Request interrupted by user" after the last prompt means the turn is over (a terminal
    /// "No" fires no Stop): the session goes idle. Returns true if anything changed.
    @discardableResult
    public func reconcile(only: String? = nil, now: Date = Date()) -> Bool {
        lock.lock()
        let watch = sessions.values.filter { s in
            (only == nil || s.sessionId == only) && s.endedAt == nil
                && (s.inTerminal || s.working || pending.values.contains { $0.req.sessionId == s.sessionId })
        }
        let jobs: [(String, String, UInt64, Date?)] = watch.compactMap { s in
            scan[s.sessionId].map { (s.sessionId, $0.path, $0.offset, s.lastPromptAt) }
        }
        lock.unlock()

        var changed = false
        for (sid, path, offset, promptAt) in jobs {
            guard let (found, newOffset) = scanTranscript(path: path, from: offset) else { continue }
            lock.lock()
            if scan[sid]?.path == path { scan[sid] = (path, newOffset) }
            var stale: [String] = []
            if var s = sessions[sid] {
                for (tuid, isError) in found.results {
                    if let i = s.steps.firstIndex(where: { $0.step.id == tuid && $0.step.pending }) {
                        s.steps[i].step.pending = false
                        s.steps[i].step.isError = isError
                        changed = true
                    }
                    stale += pending.filter { $0.value.req.sessionId == sid && $0.value.req.stepId == tuid }.map { $0.key }
                }
                if let at = found.interruptedAt, at >= (promptAt ?? .distantPast) {
                    if s.working || s.inTerminal { changed = true }
                    s.working = false
                    s.inTerminal = false
                    for i in s.steps.indices { s.steps[i].step.pending = false }
                    stale += pending.filter { $0.value.req.sessionId == sid && $0.value.req.agentId == nil }.map { $0.key }
                }
                sessions[sid] = s
            }
            let conns = settleLocked(Array(Set(stale)), now: now)
            lock.unlock()
            conns.forEach { $0.release() }
            if !conns.isEmpty { changed = true }
        }
        if changed && only == nil { onChange() }
        return changed
    }

    // MARK: decisions

    /// Register a decision request. The connection stays open until `decide` or the server releases it.
    /// `holdUntil` is when the hook gives up; decisions are taken until `decisionMargin` before that.
    @discardableResult
    public func addPending(conn: HookConnection, event: String, input: [String: Any], fingerprint: String?,
                           deadline holdUntil: Date, terminal: Bool = false, term: TerminalEnv? = nil,
                           now: Date = Date()) -> PendingRequest? {
        guard let sid = input["session_id"] as? String, !sid.isEmpty else { return nil }
        let tool = input["tool_name"] as? String ?? "?"
        let ti = input["tool_input"] as? [String: Any] ?? [:]
        let isQuestion = tool == askToolName
        let fp = fingerprint ?? inputFingerprint(ti)
        lock.lock()
        eventCount += 1
        var s = touchLocked(sid, input, terminal: terminal, term: term, now: now)
        s.endedAt = nil
        s.doneAt = nil
        s.inTerminal = false
        if event == "PreToolUse" { s.working = true; addStepLocked(&s, input, fingerprint: fp, now: now) }
        sessions[sid] = s
        let step = event == "PreToolUse" ? input["tool_use_id"] as? String
                                         : correlateLocked(sessionId: sid, toolName: tool, fingerprint: fp)
        // The same call already handed to the terminal (a question's PreToolUse, then its PermissionRequest):
        // don't ask twice. Released at once, the hook prints nothing and the terminal keeps the prompt.
        if let st = step, handedOff.removeValue(forKey: sid + "|" + st) != nil {
            lock.unlock()
            return nil
        }
        let margin = min(decisionMargin, max(0, holdUntil.timeIntervalSince(now)) * 0.25)
        var req = PendingRequest(id: conn.id, sessionId: sid, kind: isQuestion ? .question : .permission, event: event,
                                 toolName: tool, cwd: s.cwd, permissionMode: input["permission_mode"] as? String,
                                 createdAt: now, deadline: holdUntil.addingTimeInterval(-margin),
                                 preview: permissionPreview(toolName: tool, input: ti),
                                 questions: isQuestion ? parseQuestions(ti) : [], stepId: step, inputFP: fp)
        req.hasTerminal = terminal
        req.agentId = input["agent_id"] as? String
        pending[req.id] = (req, conn)
        lock.unlock()
        onChange()
        return req
    }

    /// The server dropped a held connection (decided, hook gone, or deadline).
    public func released(_ id: String) {
        lock.lock()
        let had = pending.removeValue(forKey: id) != nil
        lock.unlock()
        if had { onChange() }
    }

    /// THE decision function. The bubble's buttons and `Crewshelf --ctl` both end here.
    public func decide(_ id: String, _ d: HookDecision, now: Date = Date()) -> Result<PendingRequest, DecideError> {
        // First catch up on the transcript: a call already answered in the terminal must not be "approved" here.
        lock.lock()
        let sid = pending[id]?.req.sessionId
        lock.unlock()
        if let sid = sid, d.kind != .terminal { reconcile(only: sid, now: now) }

        lock.lock()
        guard let (req, conn) = pending[id] else {
            let elsewhere = settledElsewhere[id] != nil
            lock.unlock()
            if sid != nil { onChange() }
            return .failure(elsewhere ? .answeredElsewhere : .unknown)
        }
        if now >= req.deadline {
            pending[id] = nil
            lock.unlock()
            conn.release()
            onChange()
            return .failure(.expired)
        }
        switch (req.kind, d.kind) {
        case (_, .terminal), (.permission, .deny): break
        case (.permission, .allow):
            if req.preview.tooLong { lock.unlock(); return .failure(.tooLong) }
        case (.question, .answer):
            guard let a = d.answers, answersValid(a, questions: req.questions.map { $0.question }) else {
                lock.unlock()
                return .failure(.badAnswers)
            }
        default:
            lock.unlock()
            return .failure(.wrongKind)
        }
        pending[id] = nil
        if var s = sessions[req.sessionId] {
            if d.kind == .terminal { s.inTerminal = true } else { s.working = true; s.lastEventAt = now }
            sessions[req.sessionId] = s
        }
        if d.kind == .terminal, let st = req.stepId, req.event == "PreToolUse" {
            if handedOff.count > 200 { handedOff = handedOff.filter { now.timeIntervalSince($0.value) < 900 } }
            handedOff[req.sessionId + "|" + st] = now
        }
        lock.unlock()
        let sent = d.kind == .terminal ? { conn.release(); return true }() : conn.respond(d.wire)
        onChange()
        return sent ? .success(req) : .failure(.hookGone)
    }

    // MARK: socket requests

    /// Route one request from the socket: hook events, hook decision requests, and `--ctl` commands.
    public func handle(_ conn: HookConnection, _ obj: [String: Any]) -> HookHold {
        guard (obj["v"] as? Int) == hookWireVersion else { return .close }
        let fp = obj["input_fp"] as? String
        let terminal = obj["terminal"] as? Bool
        let term = TerminalEnv(wire: obj["term"])
        if controlOnly && (obj["kind"] as? String) != "ctl" { return .close }     // demo: no real hook ever lands here
        switch obj["kind"] as? String {
        case "event":
            if let ev = obj["event"] as? String, let input = obj["input"] as? [String: Any] {
                handleEvent(ev, input: input, fingerprint: fp, terminal: terminal, term: term)
            }
            return .close
        case "decide":
            guard let ev = obj["event"] as? String, let input = obj["input"] as? [String: Any],
                  hookWantsDecision(event: ev, input: input, terminal: terminal ?? false),
                  let dl = obj["deadline"] as? Double else { return .close }
            let holdUntil = min(Date(timeIntervalSince1970: dl), Date().addingTimeInterval(600))
            guard holdUntil > Date(), addPending(conn: conn, event: ev, input: input, fingerprint: fp, deadline: holdUntil,
                                                 terminal: terminal ?? false, term: term) != nil
            else { return .close }
            return .hold(until: holdUntil)
        case "ctl":
            conn.respond(control(obj))
            return .close
        default:
            return .close
        }
    }

    func control(_ obj: [String: Any]) -> [String: Any] {
        switch obj["op"] as? String {
        case "list":
            let list: [[String: Any]] = snapshot().pending.map { r in
                var d: [String: Any] = ["id": r.id, "session_id": r.sessionId, "kind": r.kind.rawValue, "tool": r.toolName,
                                        "summary": r.summary, "seconds_left": Int(r.deadline.timeIntervalSinceNow),
                                        "terminal": r.hasTerminal, "warnings": r.preview.warnings]
                if r.kind == .question { d["questions"] = r.questions.map { q in ["question": q.question, "options": q.options.map { $0.label }, "multiSelect": q.multiSelect] } }
                return d
            }
            let sess: [[String: Any]] = snapshot().sessions.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(20).map { s in
                ["session_id": s.sessionId, "working": s.working, "in_terminal": s.inTerminal, "ended": s.endedAt != nil,
                 "pending_steps": s.steps.filter { $0.step.pending }.map { $0.step.name }, "has_terminal": s.hasTerminal.map { $0 as Any } ?? NSNull()]
            }
            return ["ok": true, "pending": list, "sessions": sess, "control": allowControlDecisions]
        case "decide":
            guard allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            guard let id = obj["id"] as? String, let k = (obj["decision"] as? String).flatMap(HookDecisionKind.init),
                  k != .answer else { return ["ok": false, "error": "usage: decide <id> allow|deny|terminal"] }
            return reply(decide(id, HookDecision(k, message: obj["message"] as? String)))
        case "answer":
            guard allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            guard let id = obj["id"] as? String, let a = obj["answers"] as? [String: String] else {
                return ["ok": false, "error": "usage: answer <id> '{\"question\":\"label\"}'"]
            }
            return reply(decide(id, HookDecision(.answer, answers: a)))
        case "tap", "open":
            // A tap opens a bubble (its buttons then answer through the UI) and Open runs AppleScript or a CLI.
            guard allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            return uiControl(obj) ?? ["ok": false, "error": "unknown op"]
        default:
            return uiControl(obj) ?? ["ok": false, "error": "unknown op"]
        }
    }

    private func reply(_ r: Result<PendingRequest, DecideError>) -> [String: Any] {
        switch r {
        case .success(let req): return ["ok": true, "id": req.id]
        case .failure(let e): return ["ok": false, "error": e.rawValue]
        }
    }

    /// Forget sessions that ended or went quiet long ago (a killed process never sends SessionEnd).
    public func prune(now: Date = Date(), endedKeep: TimeInterval = 300, quietKeep: TimeInterval = 6 * 3600) {
        lock.lock()
        let busy = Set(pending.values.map { $0.req.sessionId })
        sessions = sessions.filter { id, s in
            if busy.contains(id) { return true }
            if let e = s.endedAt { return now.timeIntervalSince(e) < endedKeep }
            return now.timeIntervalSince(s.lastEventAt) < quietKeep
        }
        scan = scan.filter { sessions[$0.key] != nil }
        lock.unlock()
    }
}

func fileSize(_ path: String) -> UInt64 {
    var st = stat()
    return stat(path, &st) == 0 ? UInt64(st.st_size) : 0
}

/// What a stretch of transcript says about calls answered outside Crewshelf.
public struct TranscriptFindings: Equatable {
    public var results: [String: Bool] = [:]     // tool_use_id -> is_error
    public var interruptedAt: Date?              // latest "[Request interrupted by user" in the main chain
}

/// Parse complete transcript lines (main chain only) for tool results and interrupts.
public func transcriptFindings(_ text: Substring, now: Date = Date()) -> TranscriptFindings {
    var f = TranscriptFindings()
    for line in text.split(separator: "\n") where line.contains("tool_result") || line.contains("Request interrupted") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              (o["type"] as? String) == "user", (o["isSidechain"] as? Bool) != true,
              let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        for c in content {
            if (c["type"] as? String) == "tool_result", let id = c["tool_use_id"] as? String {
                f.results[id] = (c["is_error"] as? Bool) ?? false
            } else if (c["type"] as? String) == "text", (c["text"] as? String)?.hasPrefix("[Request interrupted by user") == true {
                let at = isoDate(o["timestamp"]) ?? now
                f.interruptedAt = max(f.interruptedAt ?? at, at)
            }
        }
    }
    return f
}

/// Read a transcript from `from` to its last complete line. Returns the findings and the new offset, or nil if
/// the file can't be read. A file that shrank (rewritten) restarts at its end. At most 16 MB is read per call.
public func scanTranscript(path: String, from: UInt64) -> (TranscriptFindings, UInt64)? {
    let size = fileSize(path)
    if size < from { return (TranscriptFindings(), size) }
    if size == from { return (TranscriptFindings(), from) }
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let cap: UInt64 = 16 << 20
    let start = size - from > cap ? size - cap : from
    do { try fh.seek(toOffset: start) } catch { return nil }
    let data = fh.readData(ofLength: Int(size - start))
    guard let nl = data.lastIndex(of: 10) else { return (TranscriptFindings(), start) }
    let text = String(decoding: data[data.startIndex...nl], as: UTF8.self)
    return (transcriptFindings(Substring(text)), start + UInt64(nl - data.startIndex + 1))
}
