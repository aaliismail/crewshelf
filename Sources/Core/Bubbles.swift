import Foundation

/// The one open speech bubble. Rules:
/// - At most one bubble is open. On its own it opens only for the oldest unanswered hook request (a permission
///   or a question). Every other agent waiting on you shows only its "!" until its turn.
/// - Answering or dismissing the open request opens the next one. Dismissing only hides it: the request is still
///   pending, the character keeps its "!", and a click brings it back.
/// - A finished turn never opens a bubble. The character gets a check mark that stays until you click it or the
///   agent works again; a click shows "Done". The Done bubble fades after 10 s unless hovered; clicking the
///   character brings it back.
/// - A click on a collapsed shelf's character expands the shelf and shows that character's bubble. The second click
///   of a double-click undoes what the first click did and collapses or expands instead, so a double-click never
///   dismisses anything.
/// - Collapsed: nothing opens on its own. Neither does a muted agent, one whose terminal tab you are looking
///   at, or anything while alerts are Off or Do Not Disturb is on (`autoOpen` false / `holdBack`).
/// - Only hook requests count as "needs you" (the "!" and the collapsed count): they can be answered here.
///   A session without the plugin that waits gets a dim marker instead, and a dim count when collapsed.
public struct BubbleItem: Equatable {
    public enum Kind: Int { case prompt = 0, finished = 1, manual = 2 }
    public var sessionId: String
    public var kind: Kind
    public var key: String
    public var summary: String?
    public var openedAt = Date()
}

public struct DoneMark: Equatable {
    public var key: String
    public var at: Date
    public var summary: String?
}

public struct BubbleQueue: Equatable {
    public private(set) var open: BubbleItem?
    public private(set) var dismissed: [String] = []      // prompt keys hidden by the user, most recent last (persisted)
    public private(set) var doneMarks: [String: DoneMark] = [:]   // sessionId -> check mark above its head
    public var collapsed = false
    public var doneFade: TimeInterval = 10
    public var autoOpenEnabled = true                     // false: alerts Off or Do Not Disturb
    public var holdBack: Set<String> = []                 // sessions that may not open on their own right now
    public private(set) var recentDone: [String: DoneMark] = [:]   // Done bubbles already read: a click reopens them
    private var fadeFrom: Date?
    private var lastLook: [String: Look] = [:]
    private var seenDone: [String] = []                   // Stop keys already marked, so one Stop gives one mark
    private var beforeClick: ClickUndo?                   // the state before the last single click, for a double-click

    private struct ClickUndo: Equatable {
        var sessionId: String
        var at: Date
        var open: BubbleItem?
        var dismissed: [String]
        var doneMarks: [String: DoneMark]
        var recentDone: [String: DoneMark]
        var collapsed: Bool
        var fadeFrom: Date?
    }

    public init(dismissed: [String] = [], collapsed: Bool = false) {
        self.dismissed = dismissed
        self.collapsed = collapsed
    }

    public static func finishedKey(_ s: Session) -> String {
        if let k = s.doneKey { return k }
        return [s.sessionId, "done", s.since.map { String(Int($0.timeIntervalSince1970)) } ?? "-"].joined(separator: "|")
    }

    public var visible: [BubbleItem] { open.map { [$0] } ?? [] }

    /// Feed one poll. `summary` gives the one-line last message of a session that just finished.
    /// Returns true when the open bubble or a check mark changed.
    @discardableResult
    public mutating func update(_ sessions: [Session], now: Date = Date(), summary: (Session) -> String?) -> Bool {
        let before = (open, doneMarks)
        let byId = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        if let it = open, stale(it, byId[it.sessionId]) { open = nil }

        for s in sessions {
            let now_ = look(for: s)
            let finished = s.hooked ? (s.doneKey != nil && now_ != .working && now_ != .blocked)
                                    : (lastLook[s.sessionId] == .working && (now_ == .idle || now_ == .done))
            let key = BubbleQueue.finishedKey(s)
            if finished && !seenDone.contains(key) {
                seenDone.append(key)
                if seenDone.count > 300 { seenDone.removeFirst(seenDone.count - 300) }
                doneMarks[s.sessionId] = DoneMark(key: key, at: now, summary: summary(s))
            }
            lastLook[s.sessionId] = now_
        }
        lastLook = lastLook.filter { byId[$0.key] != nil }
        doneMarks = doneMarks.filter { id, _ in
            guard let s = byId[id] else { return false }
            let lk = look(for: s)
            return lk != .working && lk != .blocked
        }
        recentDone = recentDone.filter { id, m in
            guard let s = byId[id], doneMarks[id] == nil || doneMarks[id]?.key == m.key else { return false }
            let lk = look(for: s)
            return lk != .working && lk != .blocked
        }
        autoOpen(sessions)
        return before.0 != open || before.1 != doneMarks
    }

    private func stale(_ it: BubbleItem, _ s: Session?) -> Bool {
        guard let s = s else { return true }
        switch it.kind {
        case .prompt: return blockKey(s) != it.key
        case .finished: return look(for: s) == .working || s.state == .blocked
        case .manual: return s.isFinished
        }
    }

    /// Hook requests that may open on their own, oldest first.
    public func queue(_ sessions: [Session]) -> [Session] {
        sessions.filter { $0.pendingKey != nil && blockKey($0).map { !dismissed.contains($0) } == true }
            .sorted { a, b in
                let ta = a.since ?? .distantPast, tb = b.since ?? .distantPast
                return ta != tb ? ta < tb : a.sessionId < b.sessionId
            }
    }

    /// Open the oldest waiting request if nothing is open, the shelf is expanded and alerts allow it.
    public mutating func autoOpen(_ sessions: [Session], now: Date = Date()) {
        guard open == nil, !collapsed, autoOpenEnabled,
              let s = queue(sessions).first(where: { !holdBack.contains($0.sessionId) }), let key = blockKey(s) else { return }
        open = BubbleItem(sessionId: s.sessionId, kind: .prompt, key: key, summary: nil, openedAt: now)
    }

    /// A Done bubble fades `doneFade` seconds after it opened, or after the pointer last left it. Returns true
    /// when it faded. It stays in `recentDone`, so clicking the character shows it again.
    @discardableResult
    public mutating func fadeDone(now: Date, hovering: Bool) -> Bool {
        guard let it = open, it.kind == .finished else { fadeFrom = nil; return false }
        if hovering { fadeFrom = now; return false }
        let from = max(fadeFrom ?? it.openedAt, it.openedAt)
        guard now.timeIntervalSince(from) >= doneFade else { return false }
        open = nil
        fadeFrom = nil
        return true
    }

    /// Close the open bubble. A dismissed request stays pending and keeps its "!"; it does not reopen on its own.
    public mutating func dismiss(_ item: BubbleItem) {
        guard open?.key == item.key else { return }
        open = nil
        switch item.kind {
        case .prompt:
            dismissed.append(item.key)
            if dismissed.count > 300 { dismissed.removeFirst(dismissed.count - 300) }
        case .finished:
            doneMarks[item.sessionId] = nil
            recentDone[item.sessionId] = nil
        case .manual:
            break
        }
    }

    /// A click on a character, as the shelf gets it. `count` is the event's click count: 2 is the second click of
    /// a double-click, which puts back the state from before the first click (made within `doubleClickInterval`
    /// on the same character) and then collapses or expands. Any other click is a tap; on a collapsed shelf it
    /// expands the shelf and shows this character's bubble. Whatever closes, the next waiting request opens.
    public mutating func click(_ s: Session, count: Int = 1, sessions: [Session], now: Date = Date(),
                               doubleClickInterval: TimeInterval = 0.5) {
        if count == 2, let u = beforeClick, u.sessionId == s.sessionId, now.timeIntervalSince(u.at) <= doubleClickInterval {
            beforeClick = nil
            open = u.open; dismissed = u.dismissed; doneMarks = u.doneMarks; recentDone = u.recentDone
            collapsed = u.collapsed; fadeFrom = u.fadeFrom
            collapse(!collapsed, sessions: sessions, now: now)
            return
        }
        beforeClick = ClickUndo(sessionId: s.sessionId, at: now, open: open, dismissed: dismissed, doneMarks: doneMarks,
                                recentDone: recentDone, collapsed: collapsed, fadeFrom: fadeFrom)
        if collapsed {
            collapsed = false
            show(s, now: now)
        } else {
            tap(s, now: now)
        }
        if open == nil { autoOpen(sessions, now: now) }
    }

    /// Tap on a character of an expanded shelf: close its bubble if it is the open one, otherwise open its bubble
    /// in place of the current one (the replaced request is not dismissed, so it comes back when this one closes).
    public mutating func tap(_ s: Session, now: Date = Date()) {
        if let it = open, it.sessionId == s.sessionId {
            dismiss(it)
            return
        }
        show(s, now: now)
    }

    /// Open this character's bubble: its request, else its Done, else its steps.
    private mutating func show(_ s: Session, now: Date) {
        fadeFrom = nil
        if let key = blockKey(s) {
            open = BubbleItem(sessionId: s.sessionId, kind: .prompt, key: key, summary: nil, openedAt: now)
        } else if let m = doneMarks[s.sessionId] ?? recentDone[s.sessionId] {
            open = BubbleItem(sessionId: s.sessionId, kind: .finished, key: m.key, summary: m.summary, openedAt: now)
            doneMarks[s.sessionId] = nil
            recentDone[s.sessionId] = m
        } else {
            open = BubbleItem(sessionId: s.sessionId, kind: .manual, key: "manual|\(s.sessionId)", summary: nil, openedAt: now)
        }
    }

    public mutating func collapse(_ on: Bool, sessions: [Session], now: Date = Date()) {
        collapsed = on
        if on { open = nil } else { autoOpen(sessions, now: now) }
    }

    /// A request Crewshelf can answer: an open hook permission or question.
    public static func answerable(_ s: Session) -> Bool { s.pendingKey != nil && s.state == .blocked && !s.isFinished }

    /// Waiting on you somewhere Crewshelf can't answer (no plugin, or handed to the terminal): a dim marker only.
    public static func waitsElsewhere(_ s: Session) -> Bool { s.state == .blocked && !s.isFinished && s.pendingKey == nil }

    /// Characters with a request whose bubble is not open: they show the orange "!".
    public func waiting(_ sessions: [Session]) -> [Session] {
        sessions.filter { BubbleQueue.answerable($0) && $0.sessionId != open?.sessionId }
    }

    /// The collapsed shelf's count: agents with a request you can answer here.
    public func needsYouCount(_ sessions: [Session]) -> Int {
        sessions.filter { BubbleQueue.answerable($0) }.count
    }

    /// The collapsed shelf's dim count: agents waiting in their terminal, where Crewshelf can't answer them.
    public func elsewhereCount(_ sessions: [Session]) -> Int {
        sessions.filter { BubbleQueue.waitsElsewhere($0) }.count
    }

    public func hasCheck(_ id: String) -> Bool { doneMarks[id] != nil }
}

/// The shelf's settings that survive a restart.
public struct ShelfPrefs {
    public let defaults: UserDefaults
    public static let collapsedKey = "collapsed"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var collapsed: Bool {
        get { defaults.bool(forKey: ShelfPrefs.collapsedKey) }
        nonmutating set { defaults.set(newValue, forKey: ShelfPrefs.collapsedKey) }
    }

    public static let alertsKey = "alerts"
    public static let legacyLevelKey = "alertLevel"
    public static let dndKey = "dndUntil"
    public static let mutedKey = "mutedSessions"

    /// Bubbles and sound unless set. A level saved by an older Crewshelf (one "alertLevel") is read the same way.
    public var alerts: Alerts {
        get {
            if let b = defaults.object(forKey: ShelfPrefs.alertsKey) as? Int { return Alerts(bits: b) }
            return (defaults.object(forKey: ShelfPrefs.legacyLevelKey) as? Int).flatMap { Alerts(legacyLevel: $0) } ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.bits, forKey: ShelfPrefs.alertsKey)
            defaults.removeObject(forKey: ShelfPrefs.legacyLevelKey)
        }
    }

    public var dndUntil: Date? {
        get { (defaults.object(forKey: ShelfPrefs.dndKey) as? Double).map { Date(timeIntervalSince1970: $0) } }
        nonmutating set {
            if let d = newValue { defaults.set(d.timeIntervalSince1970, forKey: ShelfPrefs.dndKey) }
            else { defaults.removeObject(forKey: ShelfPrefs.dndKey) }
        }
    }

    public var muted: Set<String> {
        get { Set(defaults.stringArray(forKey: ShelfPrefs.mutedKey) ?? []) }
        nonmutating set { defaults.set(Array(newValue.sorted().suffix(200)), forKey: ShelfPrefs.mutedKey) }
    }

    public var placement: PlacementStore { PlacementStore(defaults: defaults) }

    public static let pluginSeenKey = "pluginSeen"
    public static let hideIdleKey = "hideIdle"

    /// A hook event has arrived at least once, ever: the "Install the plugin" bubble never shows again.
    public var pluginSeen: Bool {
        get { defaults.bool(forKey: ShelfPrefs.pluginSeenKey) }
        nonmutating set { defaults.set(newValue, forKey: ShelfPrefs.pluginSeenKey) }
    }

    public var hideIdle: Bool {
        get { defaults.bool(forKey: ShelfPrefs.hideIdleKey) }
        nonmutating set { defaults.set(newValue, forKey: ShelfPrefs.hideIdleKey) }
    }
}
