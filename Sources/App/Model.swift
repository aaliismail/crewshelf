import AppKit
import Combine
import Foundation

enum DragPhase { case began, moved, ended }

struct BubbleTail: Equatable {
    var x: CGFloat          // from the bubble's left edge
    var top: Bool           // the bubble hangs below the shelf, so its tail points up
}

/// Settings live in their own defaults suite when CREWSHELF_DEFAULTS is set (a test instance), else the app's.
func crewshelfDefaults() -> UserDefaults {
    if let suite = ProcessInfo.processInfo.environment["CREWSHELF_DEFAULTS"], !suite.isEmpty, let d = UserDefaults(suiteName: suite) {
        return d
    }
    return .standard
}

/// A small bubble that is not an agent's: the first-run install hint, and answers from the settings menu.
enum Notice: Equatable {
    case install                       // no hook event has ever arrived
    case connected                     // the first one just did (shown a few seconds)
    case moveToApplications(String)    // launch at login needs the app in Applications
    case loginApproval                 // macOS wants the login item approved in System Settings
    case loginError(String)
}

final class CrewshelfModel: ObservableObject {
    @Published var shelf: [Session] = []      // live sessions plus recently departed (greyed), stable order
    @Published var hoverId: String?
    @Published var bubbles = BubbleQueue()
    @Published var details: [String: Detail] = [:]       // per open bubble
    @Published var pending: [String: [PendingRequest]] = [:]   // open hook requests per session, oldest first
    @Published var picks: [String: [Int: [String]]] = [:]       // question request id -> question index -> labels
    @Published var other: [String: [Int: String]] = [:]         // question request id -> "Other" text
    @Published var flash: [String: String] = [:]
    @Published var hint: [String: String] = [:]           // hovered button's explanation, per bubble
    @Published var busy = false
    @Published var confirmEnd: Set<String> = []
    @Published var now = Date()
    @Published var freshBlocked: [String: Date] = [:]
    @Published var shelfSide: (h: HSide, v: VSide) = (.right, .bottom)
    @Published var bubbleTail = BubbleTail(x: 270, top: false)
    @Published var bubbleCut: CGFloat = 0        // taken off the bubble's scrolling part so it fits beside the shelf
    @Published private(set) var calm: Calm
    @Published var notice: Notice?
    @Published var noticeFlash: String?
    @Published private(set) var hideIdle: Bool
    /// The shelf is on screen (not covered, screen not locked, display awake). Animations and the live clock only
    /// run while it is: nobody sees them otherwise.
    @Published var onScreen = true
    var bubbleHover = false
    var charFrames: [String: CGRect] = [:]      // characters in the shelf window (y down), for the tail and menus
    var probes: [String: CGRect] = [:]          // named controls in the bubble window, for --ctl layout
    var shelfProbes: [String: CGRect] = [:]
    var onDrag: ((DragPhase, CGPoint) -> Void)?
    var onControl: (([String: Any]) -> [String: Any]?)?
    private var alertCtx = AlertContext()
    private var screensAsleep = false
    var awayOverride: Bool?       // test control (`--ctl screen away|back|real`): pretend the screen is locked or not

    let engine: Engine
    let demo: DemoDriver?             // `--demo`: fake agents only; no roster, no real hooks, no real socket
    let notifier = Notifier()
    let hooks = HookCenter()
    private var server: HookServer?
    @Published var serverError: String?
    let queue = DispatchQueue(label: "crewshelf.engine", qos: .utility)
    private var timer: Timer?
    private var polling = false
    private var pollAgain = false
    private var bubbleGen = 0
    private var watcher = BlockWatcher()
    private var departures = Departures()
    private let dismissedPath = crewshelfSupportDir() + "/dismissed.json"
    let prefs = ShelfPrefs(defaults: crewshelfDefaults())
    private var arm = ArmGate()
    var onLayout: (() -> Void)?

    init(demo isDemo: Bool = false) {
        if isDemo {
            engine = Engine(claudeDir: crewshelfSupportDir() + "/no-claude")
            engine.rosterOff = true
            engine.stepRunner = { _ in (false, "demo") }
            demo = DemoDriver(hooks: hooks)
        } else {
            engine = Engine()
            demo = nil
        }
        hideIdle = prefs.hideIdle
        let keys = FileManager.default.contents(atPath: dismissedPath)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String] } ?? []
        bubbles = BubbleQueue(dismissed: keys, collapsed: prefs.collapsed)
        calm = Calm(alerts: prefs.alerts, dndUntil: prefs.dndUntil, muted: prefs.muted)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = true }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = false }
    }

    // MARK: quiet controls (right-click menu)

    func setAlerts(_ a: Alerts) { calm.alerts = a; prefs.alerts = a; poll() }

    func setDND(_ until: Date?) { calm.dndUntil = until; prefs.dndUntil = until; poll() }

    func toggleMute(_ id: String) {
        if calm.muted.contains(id) { calm.muted.remove(id) } else { calm.muted.insert(id) }
        prefs.muted = calm.muted
        poll()
    }

    func unmuteAll() { calm.muted = []; prefs.muted = []; poll() }

    func setHideIdle(_ on: Bool) { hideIdle = on; prefs.hideIdle = on; onLayout?() }

    /// The characters drawn on an expanded shelf (idle ones left out when "Hide idle agents" is on).
    var shownShelf: [Session] {
        var keep = Set(shelf.filter { bubbles.hasCheck($0.sessionId) }.map { $0.sessionId })
        if let o = bubbles.open { keep.insert(o.sessionId) }
        return shownOnShelf(shelf, hideIdle: hideIdle, keep: keep)
    }

    func showNotice(_ n: Notice?) { notice = n; noticeFlash = nil; onLayout?() }

    /// The first hook event ever: the install hint turns into "connected" for a few seconds, then goes for good.
    private func noteHookEvents() {
        guard demo == nil, !prefs.pluginSeen, hooks.eventsSeen > 0 else { return }
        prefs.pluginSeen = true
        guard notice == .install else { return }
        showNotice(.connected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == .connected { self?.showNotice(nil) }
        }
    }

    /// Locked screen or displays asleep: you are not looking, so a banner may go out at once.
    func away() -> Bool {
        if let o = awayOverride { return o }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return locked || screensAsleep
    }

    /// One soft sound at most every 15 s (when Sound is on), a grouped banner only when Banners is on and a request waited
    /// 30 s (or the screen is locked). Collapsing only stops bubbles: the sound and banner rules are the same.
    func alertTick() {
        alertCtx.away = away()
        let a = calm.tick(alertRequests(shelf, pending: pending), alertCtx, now: Date())
        if a.sound { notifier.chime() }
        if let t = bannerText(a.banner) { notifier.banner(title: t.title, body: t.body) }
    }

    /// Which sessions may open their bubble on their own now (Bubbles on, no DND, not muted, tab not focused).
    func applyHolds(_ q: inout BubbleQueue, sessions: [Session], ctx: AlertContext, calm c: Calm, now: Date) {
        q.autoOpenEnabled = c.alerts.bubbles && !c.dnd(now)
        q.holdBack = Set(sessions.map { $0.sessionId }.filter { !c.mayInterrupt($0, ctx, now: now) })
    }

    var collapsed: Bool { bubbles.collapsed }

    /// The one character a collapsed shelf shows: the oldest request, else anyone waiting, else working, else first.
    var collapsedFace: Session? {
        bubbles.queue(shelf).first ?? shelf.first { $0.state == .blocked && !$0.isFinished }
            ?? shelf.first { look(for: $0) == .working } ?? shelf.first
    }

    func setCollapsed(_ on: Bool) {
        bubbles.collapse(on, sessions: shelf)
        prefs.collapsed = on
        bubbleGen += 1
        onLayout?()
    }

    func session(_ id: String) -> Session? { shelf.first { $0.sessionId == id } }

    /// Bind the hook socket (where the plugin's hooks ask for decisions), before anything shows. Only the copy that
    /// owns it writes `app-path`; a demo never does. False when another Crewshelf owns it: this copy must quit.
    func claimSocket() -> Bool {
        hooks.onChange = { [weak self] in DispatchQueue.main.async { self?.poll() } }
        hooks.uiControl = { [weak self] obj in self?.control(obj) }
        hooks.allowControlDecisions = ProcessInfo.processInfo.environment["CREWSHELF_TEST_CONTROL"] == "1"
        hooks.controlOnly = demo != nil
        let srv = HookServer(path: crewshelfSocketPath())
        srv.handler = { [weak self] conn, obj in self?.hooks.handle(conn, obj) ?? .close }
        srv.onRelease = { [weak self] conn, _ in self?.hooks.released(conn.id) }
        switch claimHookSocket(srv, appPathFile: demo == nil ? crewshelfSupportDir() + "/app-path" : nil,
                               bundlePath: Bundle.main.bundlePath) {
        case .owner:
            server = srv
        case .otherRunning where demo == nil:
            // Another Crewshelf (the login item and a copy opened from Downloads, say) already owns the socket.
            FileHandle.standardError.write("crewshelf: another Crewshelf is running on \(crewshelfSocketPath()); quitting\n".data(using: .utf8)!)
            return false
        case .otherRunning:
            serverError = "Hook socket unavailable: another demo is running"
        case .failed(let e):
            serverError = "Hook socket unavailable: \(e)"
        }
        if let e = serverError { FileHandle.standardError.write("crewshelf: \(e)\n".data(using: .utf8)!) }
        return true
    }

    /// Start polling. `claimSocket` ran first.
    func start() {
        if demo == nil && !prefs.pluginSeen { showNotice(.install) }
        if let d = demo {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in d.tick() }
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // A call answered in the terminal only shows in its transcript: catch it within a second.
            if self.hooks.needsReconcile { self.queue.async { self.hooks.reconcile() } }
            if !self.pending.isEmpty {
                if self.onScreen { self.now = Date() }
                self.alertTick()
            }
            if self.calm.expireDND(Date()) { self.prefs.dndUntil = nil; self.poll() }
            if self.bubbles.fadeDone(now: Date(), hovering: self.bubbleHover) {
                self.bubbleGen += 1
                self.bubbleHover = false
                self.onLayout?()
            }
        }
    }

    func stop() {
        server?.stop()
        if demo != nil {           // a demo leaves nothing behind: its socket is gone, then its file and folder
            unlink(dismissedPath)
            rmdir(crewshelfSupportDir())    // only if nothing else is in it
        }
    }

    /// Test control (`--ctl decide` can approve) is on in a real, non-demo instance: the shelf says so.
    var testControlBadge: Bool { hooks.allowControlDecisions && demo == nil }

    /// The install hint can be brought back from the menu until the plugin has reported in once.
    var canShowInstallHint: Bool { demo == nil && !prefs.pluginSeen }

    func poll() {
        guard !polling else { pollAgain = true; return }
        polling = true
        var queueCopy = bubbles
        let gen = bubbleGen
        let calmNow = calm
        let away = self.away()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        queue.async { [weak self] in
            guard let self = self else { return }
            self.hooks.prune()
            let hook = self.hooks.snapshot()
            let all = mergeHookSessions(self.demo?.roster() ?? self.engine.snapshot(), hooks: hook.sessions, pending: hook.pending)
            let pendingBy = Dictionary(grouping: hook.pending, by: { $0.sessionId })
            let visible = self.engine.hidden.visible(all)
            let ghosts = self.departures.update(visible)
            let fresh = self.watcher.newlyBlocked(visible)
            let asking = visible.filter { BubbleQueue.answerable($0) || (!$0.hooked && BubbleQueue.waitsElsewhere($0)) }
            let focused = asking.isEmpty || self.demo != nil ? [] : self.engine.focusedSessions(asking, frontmost: front)
            let ctx = AlertContext(away: away, focusedSessions: focused, focusMode: focusIsOn())
            let ordered = (visible + ghosts).sorted { a, b in
                let ta = a.startedAt ?? .distantPast, tb = b.startedAt ?? .distantPast
                return ta != tb ? ta < tb : a.sessionId < b.sessionId
            }
            self.applyHolds(&queueCopy, sessions: ordered, ctx: ctx, calm: calmNow, now: Date())
            queueCopy.update(ordered) { s in
                (s.doneText ?? self.engine.transcript(for: s, limit: 1)?.lastText).map { oneLine($0, max: 160) }
            }
            var details: [String: Detail] = [:]
            for it in queueCopy.visible {
                guard let s = ordered.first(where: { $0.sessionId == it.sessionId }) else { continue }
                details[s.sessionId] = self.engine.detail(for: s, limit: 6)
            }
            DispatchQueue.main.async {
                // Only what changed is published: an unchanged poll redraws nothing and lays nothing out.
                var changed = false
                self.polling = false
                changed = self.update(\.pending, pendingBy) || changed
                let live = Set(hook.pending.map { $0.id })
                changed = self.update(\.picks, self.picks.filter { live.contains($0.key) }) || changed
                changed = self.update(\.other, self.other.filter { live.contains($0.key) }) || changed
                changed = self.update(\.shelf, ordered) || changed
                var q = queueCopy
                if gen != self.bubbleGen {      // a click or dismissal happened meanwhile: replay this poll onto it
                    let summaries = queueCopy.doneMarks.mapValues { $0.summary }
                    q = self.bubbles
                    self.applyHolds(&q, sessions: ordered, ctx: ctx, calm: self.calm, now: Date())
                    q.update(ordered) { summaries[$0.sessionId] ?? nil }
                }
                changed = self.update(\.bubbles, q) || changed
                var fb = self.freshBlocked
                for s in fresh { fb[s.sessionId] = Date() }     // the hop
                self.alertCtx = ctx
                self.alertTick()
                let blockedIds = Set(visible.filter { $0.state == .blocked }.map { $0.sessionId })
                fb = fb.filter { id, at in Date().timeIntervalSince(at) < 60 && blockedIds.contains(id) }
                changed = self.update(\.freshBlocked, fb) || changed
                changed = self.update(\.details, details) || changed
                // The clock only matters where a time shows or runs out: an open bubble, a tooltip, a hop.
                let clock = self.onScreen && (self.bubbles.open != nil || self.hoverId != nil || !blockedIds.isEmpty)
                if changed || clock { self.now = Date() }
                self.noteHookEvents()
                if changed || clock { self.onLayout?() }
                if self.pollAgain { self.pollAgain = false; self.poll() }
            }
        }
    }

    /// Set a published value only when it differs, so SwiftUI is not told about a change that is not one.
    @discardableResult
    private func update<T: Equatable>(_ kp: ReferenceWritableKeyPath<CrewshelfModel, T>, _ v: T) -> Bool {
        guard self[keyPath: kp] != v else { return false }
        self[keyPath: kp] = v
        return true
    }

    func isFresh(_ s: Session) -> Bool {
        if freshBlocked[s.sessionId] != nil { return true }
        guard s.state == .blocked, let since = s.since else { return false }
        return now.timeIntervalSince(since) < 60
    }

    /// A click on a character (`clickCount` 2: the second click of a double-click, which collapses or expands
    /// and undoes the first click). On a collapsed shelf a click expands it and shows that character's bubble.
    func tap(_ s: Session, clickCount: Int = 1) {
        guard !s.isFinished || bubbles.hasCheck(s.sessionId) else { return }
        let wasCollapsed = collapsed
        bubbles.click(s, count: clickCount, sessions: shelf, doubleClickInterval: NSEvent.doubleClickInterval)
        if collapsed != wasCollapsed { prefs.collapsed = collapsed }
        bubbleGen += 1
        saveDismissed()
        onLayout?()
        poll()
    }

    func dismiss(_ item: BubbleItem) {
        bubbles.dismiss(item)
        bubbles.autoOpen(shelf)          // the next waiting request opens at once
        bubbleGen += 1
        confirmEnd.remove(item.sessionId)
        saveDismissed()
        onLayout?()
    }

    /// `Crewshelf --ctl tap <session>`: the same tap a click does; replies with what is open afterwards.
    private func control(_ obj: [String: Any]) -> [String: Any]? {
        if (obj["op"] as? String) == "open" {
            // Open waits on AppleScript or a CLI: run it on the engine queue, like the button, not on the main thread.
            let key = obj["session"] as? String ?? ""
            guard demo == nil else { return ["ok": false, "error": "demo mode"] }
            guard let s = DispatchQueue.main.sync(execute: { engine.find(key, in: shelf) }) else {
                return ["ok": false, "error": "no session matching \(key)"]
            }
            let r = queue.sync { engine.jump(s) }
            return ["ok": r.ok, "message": r.message]
        }
        guard (obj["op"] as? String) == "tap" else {
            return DispatchQueue.main.sync { onControl?(obj) }
        }
        let key = obj["session"] as? String ?? ""
        return DispatchQueue.main.sync {
            guard let s = engine.find(key, in: shelf) else { return ["ok": false, "error": "no session matching \(key)"] }
            tap(s)
            var out: [String: Any] = ["ok": true, "session_id": s.sessionId, "collapsed": collapsed]
            if let o = bubbles.open {
                var b: [String: Any] = ["session_id": o.sessionId, "kind": ["prompt", "finished", "manual"][o.kind.rawValue]]
                if let sum = o.summary { b["summary"] = sum }
                out["open"] = b
            }
            return out
        }
    }

    private func saveDismissed() {
        if let d = try? JSONSerialization.data(withJSONObject: bubbles.dismissed) {
            FileManager.default.createFile(atPath: dismissedPath, contents: d)
        }
    }

    private func act(_ id: String, _ work: @escaping (Engine) -> ActionResult) {
        busy = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let r = work(self.engine)
            DispatchQueue.main.async {
                self.busy = false
                self.flash[id] = r.message
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.flash[id] == r.message { self?.flash[id] = nil }
                }
                self.onLayout?()
                self.poll()
            }
        }
    }

    func open(_ s: Session) {
        if demo != nil { return say(s.sessionId, "Demo: Open brings the agent's terminal tab to the front.") }
        act(s.sessionId) { $0.jump(s) }
    }

    private func say(_ id: String, _ msg: String) {
        flash[id] = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.flash[id] == msg { self?.flash[id] = nil }
        }
    }

    /// End: `claude stop` for a background agent (asks once more first); Hide for an interactive tab.
    func end(_ s: Session, _ item: BubbleItem) {
        if s.kind == .background && !confirmEnd.contains(s.sessionId) {
            confirmEnd.insert(s.sessionId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.confirmEnd.remove(s.sessionId) }
            return
        }
        confirmEnd.remove(s.sessionId)
        if let d = demo {
            d.end(s.sessionId)
            dismiss(item)
            poll()
            return
        }
        act(s.sessionId) { $0.done(s) }
        dismiss(item)
    }

    // MARK: hook decisions (the --ctl path calls the same HookCenter.decide)

    /// The bubble shows this request now. Its buttons arm after a short delay (see ArmGate).
    func see(_ req: PendingRequest) {
        arm.see(req.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + arm.delay + 0.05) { [weak self] in self?.objectWillChange.send() }
    }

    func armed(_ req: PendingRequest) -> Bool { arm.armed(req.id) }

    func decide(_ req: PendingRequest, _ d: HookDecision) {
        guard armed(req) else { return }        // a click on a request that only just appeared under the pointer
        let r = hooks.decide(req.id, d)
        let msg: String
        switch r {
        case .success:
            switch d.kind {
            case .allow: msg = "Approved."
            case .deny: msg = "Denied."
            case .terminal: msg = "Released to the terminal."
            case .answer: msg = "Answer sent."
            }
        case .failure(let e): msg = e.rawValue
        }
        flash[req.sessionId] = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.flash[req.sessionId] == msg { self?.flash[req.sessionId] = nil }
        }
        NSApp.keyWindow?.resignKey()
        poll()
    }

    func togglePick(_ req: PendingRequest, _ qi: Int, _ label: String) {
        guard qi < req.questions.count else { return }
        var cur = picks[req.id]?[qi] ?? []
        if req.questions[qi].multiSelect {
            if let i = cur.firstIndex(of: label) { cur.remove(at: i) } else { cur.append(label) }
        } else {
            cur = cur == [label] ? [] : [label]
            other[req.id, default: [:]][qi] = ""
        }
        picks[req.id, default: [:]][qi] = cur
    }

    /// Answers for every question, or nil while one is still unanswered.
    func answers(_ req: PendingRequest) -> [String: String]? {
        var out: [String: String] = [:]
        for (i, q) in req.questions.enumerated() {
            let a = answerText(picked: picks[req.id]?[i] ?? [], other: other[req.id]?[i] ?? "", multiSelect: q.multiSelect)
            guard !a.isEmpty else { return nil }
            out[q.question] = a
        }
        return out.isEmpty ? nil : out
    }

    func send(_ req: PendingRequest) {
        guard let a = answers(req) else { return }
        decide(req, HookDecision(.answer, answers: a))
    }
}
