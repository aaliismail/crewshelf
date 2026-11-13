import Foundation

// Calm notifications: only interrupt for things that need you, and as little as possible. Every rule that
// depends on time takes `now`, so the tests drive a fake clock.

/// What Crewshelf may do on its own when an agent needs you, each part on or off by itself (right-click > Alerts).
/// All off: nothing opens on its own and nothing sounds; the "!" still shows. Banners still wait for the 30 s /
/// screen-locked rule.
public struct Alerts: Equatable {
    public var bubbles: Bool          // the request's bubble opens on its own
    public var sound: Bool            // one soft sound
    public var banners: Bool          // a macOS banner

    public init(bubbles: Bool = true, sound: Bool = true, banners: Bool = false) {
        self.bubbles = bubbles; self.sound = sound; self.banners = banners
    }

    /// Bubbles and sound, no banners.
    public static let standard = Alerts()
    public static let all = Alerts(bubbles: true, sound: true, banners: true)
    public static let off = Alerts(bubbles: false, sound: false, banners: false)

    /// Stored as bits: 1 bubbles, 2 sound, 4 banners.
    public var bits: Int { (bubbles ? 1 : 0) | (sound ? 2 : 0) | (banners ? 4 : 0) }
    public init(bits: Int) { self.init(bubbles: bits & 1 != 0, sound: bits & 2 != 0, banners: bits & 4 != 0) }

    /// The single level P1.5 stored (0 off, 1 bubble only, 2 bubble + sound, 3 bubble + sound + banner).
    public init?(legacyLevel l: Int) {
        guard (0...3).contains(l) else { return nil }
        self.init(bubbles: l >= 1, sound: l >= 2, banners: l >= 3)
    }

    public var label: String {
        let on = [(bubbles, "bubbles"), (sound, "sound"), (banners, "banners")].filter { $0.0 }.map { $0.1 }
        return on.isEmpty ? "off" : on.joined(separator: " + ")
    }
}

/// A request that can be answered in Crewshelf (a hook permission or question).
public struct AlertRequest: Equatable {
    public var id: String
    public var sessionId: String
    public var name: String
    public var summary: String
    public init(id: String, sessionId: String, name: String, summary: String) {
        self.id = id; self.sessionId = sessionId; self.name = name; self.summary = summary
    }
}

/// What is true right now outside Crewshelf.
public struct AlertContext {
    public var away = false                       // screen locked or displays asleep
    public var focusedSessions: Set<String> = []  // agents whose own terminal tab is the focused one
    public var focusMode = false                  // a macOS Focus is on: no sound, no banner (bubbles still open)
    public init(away: Bool = false, focusedSessions: Set<String> = [], focusMode: Bool = false) {
        self.away = away; self.focusedSessions = focusedSessions; self.focusMode = focusMode
    }
}

/// Everything that waits on you, for the sound and banner rules: every open hook request, plus a session without
/// the plugin that waits in its terminal (nothing else would tell you about it). A hooked session you handed to
/// the terminal yourself does not alert again.
public func alertRequests(_ sessions: [Session], pending: [String: [PendingRequest]]) -> [AlertRequest] {
    sessions.flatMap { s -> [AlertRequest] in
        if BubbleQueue.answerable(s) {
            return (pending[s.sessionId] ?? []).map { AlertRequest(id: $0.id, sessionId: s.sessionId, name: s.name, summary: $0.summary) }
        }
        if !s.hooked, BubbleQueue.waitsElsewhere(s), let key = blockKey(s) {
            let what = s.needs ?? s.waitingFor.map { "Waiting for \($0) in its terminal" } ?? "Waiting in its terminal"
            return [AlertRequest(id: key, sessionId: s.sessionId, name: s.name, summary: oneLine(what, max: 160))]
        }
        return []
    }
}

public struct AlertActions: Equatable {
    public var sound = false
    public var banner: [AlertRequest] = []        // one grouped banner for all of these
}

public struct Calm {
    public var alerts: Alerts = .standard
    public var dndUntil: Date?
    public var muted: Set<String> = []
    public var soundGap: TimeInterval = 15
    public var bannerAfter: TimeInterval = 30
    public private(set) var lastSound: Date?
    private var arrived: [String: Date] = [:]     // request id -> when Crewshelf first saw it
    private var bannered: Set<String> = []
    private var seeded = false

    public init(alerts: Alerts = .standard, dndUntil: Date? = nil, muted: Set<String> = []) {
        self.alerts = alerts; self.dndUntil = dndUntil; self.muted = muted
    }

    public func dnd(_ now: Date) -> Bool { dndUntil.map { now < $0 } ?? false }

    /// Do Not Disturb that ended is forgotten. True when it just expired.
    public mutating func expireDND(_ now: Date) -> Bool {
        guard let u = dndUntil, now >= u else { return false }
        dndUntil = nil
        return true
    }

    /// Whether this agent may interrupt at all right now: not muted, no DND, and you are not already looking
    /// at its terminal tab (unless the screen is locked, then you are not looking at anything).
    public func mayInterrupt(_ sessionId: String, _ ctx: AlertContext, now: Date) -> Bool {
        !dnd(now) && !muted.contains(sessionId) && (ctx.away || !ctx.focusedSessions.contains(sessionId))
    }

    /// Whether this agent's bubble may open on its own.
    public func mayAutoOpen(_ sessionId: String, _ ctx: AlertContext, now: Date) -> Bool {
        alerts.bubbles && mayInterrupt(sessionId, ctx, now: now)
    }

    /// Feed `alertRequests` on every tick (oldest first). Returns at most one sound (never twice within
    /// `soundGap`, however many agents block together) and the requests to put in one grouped banner.
    /// Requests already open when Crewshelf starts never alert. While a macOS Focus is on nothing sounds and nothing
    /// is bannered; a request still waiting 30 s when the Focus ends gets its banner then.
    public mutating func tick(_ requests: [AlertRequest], _ ctx: AlertContext, now: Date) -> AlertActions {
        var out = AlertActions()
        let ids = Set(requests.map { $0.id })
        arrived = arrived.filter { ids.contains($0.key) }
        bannered = bannered.intersection(ids)
        let fresh = requests.filter { arrived[$0.id] == nil }
        for r in fresh { arrived[r.id] = now }
        guard seeded else {
            seeded = true
            bannered.formUnion(fresh.map { $0.id })
            return out
        }
        let live = ctx.focusMode ? [] : requests.filter { mayInterrupt($0.sessionId, ctx, now: now) }
        if alerts.sound, live.contains(where: { r in fresh.contains { $0.id == r.id } }),
           lastSound.map({ now.timeIntervalSince($0) >= soundGap }) ?? true {
            out.sound = true
            lastSound = now
        }
        if alerts.banners {
            out.banner = live.filter { r in
                !bannered.contains(r.id) && (ctx.away || now.timeIntervalSince(arrived[r.id] ?? now) >= bannerAfter)
            }
            bannered.formUnion(out.banner.map { $0.id })
        }
        return out
    }
}

/// Banner text with control characters (NUL, newlines, escapes) turned into spaces: agent text goes into an
/// osascript argument, and a NUL there can't be passed to a program at all.
public func bannerSafe(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : $0 }))
}

/// One banner for a group of requests.
public func bannerText(_ group: [AlertRequest]) -> (title: String, body: String)? {
    guard let first = group.first else { return nil }
    if group.count == 1 { return ("\(first.name) needs you", first.summary) }
    let names = group.map { $0.name }
    let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
    return ("\(group.count) agents need you", shown)
}

/// "Until tomorrow": 8:00 the next morning (or this morning, when it is still before 8:00).
public func nextMorning(after now: Date, calendar: Calendar = .current, hour: Int = 8) -> Date {
    let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(86400)
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
}

/// The cmux surface that has keyboard focus: in the key window, the selected workspace, the focused pane,
/// the selected tab. Its tty says which agent you are looking at.
public func focusedTty(cmuxTree data: Data) -> String? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let windows = root["windows"] as? [[String: Any]] else { return nil }
    func on(_ o: [String: Any], _ k: String) -> Bool { (o[k] as? Bool) == true }
    for w in windows where on(w, "key") {
        for ws in (w["workspaces"] as? [[String: Any]]) ?? [] where on(ws, "selected") {
            for p in (ws["panes"] as? [[String: Any]]) ?? [] where on(p, "focused") {
                for s in (p["surfaces"] as? [[String: Any]]) ?? [] where on(s, "selected_in_pane") || on(s, "selected") {
                    return s["tty"] as? String
                }
            }
        }
    }
    return nil
}

/// Whether a macOS Focus (Do Not Disturb, Work, Sleep, ...) is on, read from the files Control Center keeps in
/// ~/Library/DoNotDisturb/DB (there is no public API an ad-hoc signed app may use). On when a Focus was turned on
/// by hand, from another device or by a smart trigger (an assertion record in Assertions.json), or when a
/// Focus's enabled schedule covers `now` (ModeConfigurations.json: weekdays bitmask Monday = bit 0; a window that
/// passes midnight belongs to the day it starts). Unreadable files mean "off". A schedule turned off by hand
/// still reads as on, which only errs toward quiet.
public func focusIsOn(assertions: Data?, modes: Data?, now: Date, calendar: Calendar = .current) -> Bool {
    func records(_ d: Data?) -> [[String: Any]] {
        guard let d = d, let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        return root["data"] as? [[String: Any]] ?? []
    }
    if records(assertions).contains(where: { !(($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty }) { return true }
    let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
    guard let wd = c.weekday, let h = c.hour, let m = c.minute else { return false }
    let minute = h * 60 + m
    let today = (wd + 5) % 7                  // Calendar weekday 1 = Sunday -> bit 6; 2 = Monday -> bit 0
    let yesterday = (today + 6) % 7
    for r in records(modes) {
        for (_, cfg) in (r["modeConfigurations"] as? [String: Any]) ?? [:] {
            let triggers = ((cfg as? [String: Any])?["triggers"] as? [String: Any])?["triggers"] as? [[String: Any]] ?? []
            for t in triggers where (t["class"] as? String) == "DNDModeConfigurationScheduleTrigger" && (t["enabledSetting"] as? Int) == 2 {
                guard let sh = t["timePeriodStartTimeHour"] as? Int, let eh = t["timePeriodEndTimeHour"] as? Int else { continue }
                let start = sh * 60 + ((t["timePeriodStartTimeMinute"] as? Int) ?? 0)
                let end = eh * 60 + ((t["timePeriodEndTimeMinute"] as? Int) ?? 0)
                let days = (t["timePeriodWeekdays"] as? Int) ?? 127
                func on(_ day: Int) -> Bool { days & (1 << day) != 0 }
                if start < end {
                    if minute >= start && minute < end && on(today) { return true }
                } else if start > end {
                    if (minute >= start && on(today)) || (minute < end && on(yesterday)) { return true }
                }
            }
        }
    }
    return false
}

/// `focusIsOn` for this Mac.
public func focusIsOn(now: Date = Date()) -> Bool {
    let dir = NSHomeDirectory() + "/Library/DoNotDisturb/DB/"
    return focusIsOn(assertions: FileManager.default.contents(atPath: dir + "Assertions.json"),
                     modes: FileManager.default.contents(atPath: dir + "ModeConfigurations.json"), now: now)
}
