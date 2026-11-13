import Foundation

// P1.5: where the shelf sits, where its bubble opens, and the calm alert rules. All time is a fake clock.

func ar(_ id: String, _ sid: String) -> AlertRequest { AlertRequest(id: id, sessionId: sid, name: sid, summary: "Bash: ls") }

func placementTests() {
    let mainD = DisplayInfo(id: "MAIN", frame: CGRect(x: 0, y: 0, width: 1440, height: 875), isMain: true)
    let side = DisplayInfo(id: "SIDE", frame: CGRect(x: -1920, y: -200, width: 1920, height: 1050), isMain: false)
    let both = [mainD, side]
    let size = CGSize(width: 200, height: 80)

    // No saved spot: bottom-right of the main screen.
    let first = shelfFrame(spot: nil, size: size, displays: both)!
    eq(first.frame, CGRect(x: 1440 - 10 - 200, y: 10, width: 200, height: 80), "default: bottom-right corner of the main screen")
    eq(first.spot, ShelfSpot.corner("MAIN"), "default spot")

    // Drops: snapping to corners and edges, free placement otherwise.
    let nearBL = dropSpot(CGRect(x: 25, y: 30, width: 200, height: 80), displays: both)!
    eq(nearBL, ShelfSpot(display: "MAIN", h: .left, v: .bottom, dx: 10, dy: 10), "dropped near the bottom-left corner snaps to it")
    let leftEdge = dropSpot(CGRect(x: 12, y: 300, width: 200, height: 80), displays: both)!
    eq(leftEdge, ShelfSpot(display: "MAIN", h: .left, v: .bottom, dx: 10, dy: 300), "near the left edge only: snaps to the edge, keeps its height")
    let topRight = dropSpot(CGRect(x: 1440 - 230, y: 875 - 100, width: 200, height: 80), displays: both)!
    eq(topRight, ShelfSpot(display: "MAIN", h: .right, v: .top, dx: 10, dy: 10), "near the top-right corner snaps to it")
    let free = dropSpot(CGRect(x: 900, y: 500, width: 200, height: 80), displays: both)!
    eq(free, ShelfSpot(display: "MAIN", h: .right, v: .top, dx: 340, dy: 295), "dropped mid-screen: stays exactly there")
    let back = shelfFrame(spot: free, size: size, displays: both)!.frame
    eq(back, CGRect(x: 900, y: 500, width: 200, height: 80), "a free spot gives back the same frame")
    let wider = shelfFrame(spot: free, size: CGSize(width: 300, height: 80), displays: both)!.frame
    eq(wider.maxX, 1100, "a shelf on the right half grows to the left (toward the center)")
    let leftGrow = shelfFrame(spot: leftEdge, size: CGSize(width: 300, height: 80), displays: both)!.frame
    eq(leftGrow.minX, 10, "a shelf on the left edge grows to the right")
    let offEdge = dropSpot(CGRect(x: 1400, y: -40, width: 200, height: 80), displays: both)!
    let clamped = shelfFrame(spot: offEdge, size: size, displays: both)!.frame
    check(mainD.frame.contains(clamped), "a drop half off-screen comes back fully on screen: \(clamped)")
    let onSide = dropSpot(CGRect(x: -1000, y: 400, width: 200, height: 80), displays: both)!
    eq(onSide.display, "SIDE", "a drop on the second display belongs to it")
    check(side.frame.contains(shelfFrame(spot: onSide, size: size, displays: both)!.frame), "and is placed on it")

    // Display gone: back to bottom-right of the main screen; the saved spot is kept for when it returns.
    let gone = shelfFrame(spot: onSide, size: size, displays: [mainD])!
    eq(gone.frame, first.frame, "its display is gone: bottom-right of the main screen")
    eq(gone.spot.display, "MAIN", "fallback spot is on the main screen")
    let none = shelfFrame(spot: onSide, size: size, displays: [])
    check(none == nil, "no displays at all: no frame")
    // The Corner menu ticks where the shelf really is: a top-left spot on an unplugged display is bottom-right.
    let topLeftSide = ShelfSpot.corner("SIDE", .left, .top)
    check(effectiveSpot(topLeftSide, displays: [mainD])?.corner.map { $0 == (.right, .bottom) } ?? false,
          "Corner menu: snapped top-left on a display that is gone reads as bottom-right of the main screen")
    check(effectiveSpot(topLeftSide, displays: both)?.corner.map { $0 == (.left, .top) } ?? false,
          "Corner menu: the same spot reads top-left while its display is connected")
    check(effectiveSpot(nil, displays: both)?.corner.map { $0 == (.right, .bottom) } ?? false, "Corner menu: no spot is bottom-right")
    check(effectiveSpot(free, displays: both)?.corner == nil, "Corner menu: a dragged spot ticks no corner")

    // Persistence across a restart: saved per display, read back by a new process.
    let suite = "io.github.aaliismail.crewshelf.tests.place.\(getpid())"
    if let d = UserDefaults(suiteName: suite) {
        let store = PlacementStore(defaults: d)
        check(store.current == nil, "nothing saved yet")
        store.save(free)
        store.save(onSide)
        d.synchronize()
        let again = PlacementStore(defaults: UserDefaults(suiteName: suite)!)
        eq(again.current, onSide, "the last display's spot is restored")
        eq(again.spots["MAIN"], free, "each display keeps its own spot")
        eq(shelfFrame(spot: again.current, size: size, displays: both)!.frame,
           shelfFrame(spot: onSide, size: size, displays: both)!.frame, "restored spot gives the same frame")
        eq(shelfFrame(spot: again.current, size: size, displays: [mainD])!.frame, first.frame,
           "restored on a Mac where that display is gone: bottom-right of the main screen")
        if sandboxed {
            print("SKIP placement persists for a new process: `defaults` can't reach this suite from a sandboxed shell")
        } else {
            let out = run("/usr/bin/defaults", ["read", suite, PlacementStore.displayKey], timeout: 5).out
            eq(out.trimmingCharacters(in: .whitespacesAndNewlines), "SIDE", "placement persists for a new process")
        }
        dropSuite(suite)
    }

    // Bubbles open toward the screen's center and never off-screen, wherever the shelf sits.
    let screen = mainD.frame
    let bsize = CGSize(width: 316, height: 260)
    struct Case { let name: String; let shelf: CGRect; let below: Bool; let reachesLeft: Bool }
    let w: CGFloat = 200, h: CGFloat = 80
    let cases = [
        Case(name: "bottom-right", shelf: CGRect(x: screen.maxX - 10 - w, y: 10, width: w, height: h), below: false, reachesLeft: true),
        Case(name: "bottom-left", shelf: CGRect(x: 10, y: 10, width: w, height: h), below: false, reachesLeft: false),
        Case(name: "top-right", shelf: CGRect(x: screen.maxX - 10 - w, y: screen.maxY - 10 - h, width: w, height: h), below: true, reachesLeft: true),
        Case(name: "top-left", shelf: CGRect(x: 10, y: screen.maxY - 10 - h, width: w, height: h), below: true, reachesLeft: false),
        Case(name: "left edge, low", shelf: CGRect(x: 10, y: 300, width: w, height: h), below: false, reachesLeft: false),
        Case(name: "right edge, high", shelf: CGRect(x: screen.maxX - 10 - w, y: 500, width: w, height: h), below: true, reachesLeft: true),
        Case(name: "top center", shelf: CGRect(x: 620, y: screen.maxY - 10 - h, width: w, height: h), below: true, reachesLeft: true),
        Case(name: "bottom, a little left of center", shelf: CGRect(x: 500, y: 10, width: w, height: h), below: false, reachesLeft: false),
    ]
    for c in cases {
        for anchorX in [c.shelf.minX + 30, c.shelf.midX, c.shelf.maxX - 30] {
            let p = bubblePlacement(shelf: c.shelf, anchorX: anchorX, size: bsize, screen: screen)
            check(screen.contains(p.frame), "\(c.name): bubble on screen \(p.frame)")
            eq(p.below, c.below, "\(c.name): bubble opens toward the vertical center")
            if c.below { check(p.frame.maxY <= c.shelf.minY + 10, "\(c.name): bubble is under the shelf") }
            else { check(p.frame.minY >= c.shelf.maxY - 10, "\(c.name): bubble is over the shelf") }
            if c.reachesLeft { eq(p.frame.maxX, c.shelf.maxX, "\(c.name): lined up with the right edge, reaching left") }
            else { eq(p.frame.minX, c.shelf.minX, "\(c.name): lined up with the left edge, reaching right") }
            check(abs(p.frame.minX + p.tailX - anchorX) < 0.5, "\(c.name): tail points at the character")
        }
    }
    // A character far from the bubble's edge pulls the bubble along; a huge bubble is still kept on screen.
    let wide = CGRect(x: screen.maxX - 10 - 600, y: 10, width: 600, height: h)
    let far = bubblePlacement(shelf: wide, anchorX: wide.minX + 23, size: bsize, screen: screen)
    check(abs(far.frame.minX + far.tailX - (wide.minX + 23)) < 0.5 && far.tailX >= 26, "far character: bubble shifts so the tail reaches it")
    let huge = bubblePlacement(shelf: cases[0].shelf, anchorX: cases[0].shelf.midX, size: CGSize(width: 316, height: 2000), screen: screen)
    eq(huge.frame.minY, screen.minY, "a bubble taller than the screen starts at the bottom")
    // A bubble taller than the room beside the shelf: it reports the overflow, and once shortened by it (the
    // app's cut) it sits beside the shelf without covering it. Checker's probe: shelf just under the middle.
    let mid = CGRect(x: 600, y: 380, width: 240, height: 96)
    let tall = bubblePlacement(shelf: mid, anchorX: mid.midX, size: CGSize(width: 316, height: 470), screen: screen)
    check(!tall.below, "shelf just under the middle: the bubble opens above")
    eq(tall.room, 875 - (476 - 10), "room above the shelf")
    eq(tall.overflow, 470 - 409, "a 470 pt bubble overflows the 409 pt above by 61")
    let cut = bubbleCut(current: 0, height: 470, room: tall.room, maxCut: 230)
    eq(cut, 61, "the scrolling part is cut by the overflow")
    let fit = bubblePlacement(shelf: mid, anchorX: mid.midX, size: CGSize(width: 316, height: 470 - cut), screen: screen)
    check(fit.overflow == 0 && fit.frame.minY >= mid.maxY - 10 && screen.contains(fit.frame),
          "shortened: on screen and not over the shelf \(fit.frame)")
    eq(bubbleCut(current: 61, height: 409, room: 409, maxCut: 230), 61, "a bubble that fits keeps its cut (stable, no relayout loop)")
    eq(bubbleCut(current: 61, height: 409, room: 600, maxCut: 230), 0, "more room again: the cut is given back")
    eq(bubbleCut(current: 200, height: 900, room: 300, maxCut: 230), 230, "the cut never passes its maximum")
    for c in cases {
        let p = bubblePlacement(shelf: c.shelf, anchorX: c.shelf.midX, size: bsize, screen: screen)
        eq(p.overflow, 0, "\(c.name): a normal bubble fits, nothing is cut")
    }
    let onSecond = CGRect(x: -1920 + 10, y: -200 + 10, width: w, height: h)
    let p2 = bubblePlacement(shelf: onSecond, anchorX: onSecond.midX, size: bsize, screen: side.frame)
    check(side.frame.contains(p2.frame) && !p2.below, "second display (negative coordinates): above, on screen")
}

func calmTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let none = AlertContext()

    // Requests already open at launch never alert.
    var c0 = Calm(alerts: .all)
    eq(c0.tick([ar("old", "a")], none, now: at(0)), AlertActions(), "requests open at launch: no alert")
    eq(c0.tick([ar("old", "a")], none, now: at(40)).banner, [], "…not even a banner later")

    // Sound throttle: 5 blocks in 3 s give 1 sound.
    var c = Calm()
    _ = c.tick([], none, now: at(0))
    var sounds = 0
    var reqs: [AlertRequest] = []
    for i in 0..<5 {
        reqs.append(ar("r\(i)", "s\(i)"))
        if c.tick(reqs, none, now: at(Double(i) * 0.75)).sound { sounds += 1 }
    }
    eq(sounds, 1, "5 blocks in 3 s give 1 sound")
    eq(c.tick(reqs + [ar("r5", "s5")], none, now: at(10)).sound, false, "a 6th block 10 s after the sound is grouped (no sound)")
    eq(c.tick(reqs + [ar("r5", "s5"), ar("r6", "s6")], none, now: at(16)).sound, true, "a new block after 15 s sounds again")
    eq(c.tick(reqs + [ar("r5", "s5"), ar("r6", "s6")], none, now: at(40)).sound, false, "no new request: no sound")
    eq(c.tick(reqs, none, now: at(41)).banner, [], "default level: never a banner")

    // Banner escalation: only after 30 s unanswered, once, grouped; at once when the screen is locked.
    var b = Calm(alerts: .all)
    _ = b.tick([], none, now: at(0))
    let one = [ar("x", "sx")]
    let first = b.tick(one, none, now: at(1))
    check(first.sound && first.banner.isEmpty, "a new request: sound, no banner yet")
    eq(b.tick(one, none, now: at(30.9)).banner, [], "29.9 s unanswered: no banner")
    eq(b.tick(one, none, now: at(31)).banner.map { $0.id }, ["x"], "30 s unanswered: banner")
    eq(b.tick(one, none, now: at(32)).banner, [], "the banner goes out once")
    let group = [ar("x", "sx"), ar("y", "sy"), ar("z", "sz"), ar("w", "sw")]
    _ = b.tick(group, none, now: at(40))
    let g = b.tick(group, none, now: at(70)).banner
    eq(g.map { $0.id }, ["y", "z", "w"], "requests that escalate together share one banner")
    eq(bannerText(g)?.title ?? "", "3 agents need you", "grouped banner title")
    eq(bannerText([ar("x", "sx")])?.title ?? "", "sx needs you", "single banner title")
    var lk = Calm(alerts: .all)
    _ = lk.tick([], none, now: at(0))
    eq(lk.tick(one, AlertContext(away: true), now: at(1)).banner.map { $0.id }, ["x"], "screen locked: banner at once")
    var answered = Calm(alerts: .all)
    _ = answered.tick([], none, now: at(0))
    _ = answered.tick(one, none, now: at(1))
    _ = answered.tick([], none, now: at(10))
    eq(answered.tick(one, none, now: at(35)).banner, [], "answered within 30 s and back as the same id: timer restarted")

    // Alerts: bubbles, sound and banners each on or off by itself (every one of the 8 combinations).
    for bits in 0..<8 {
        let al = Alerts(bits: bits)
        var l = Calm(alerts: al)
        _ = l.tick([], none, now: at(0))
        let a1 = l.tick(one, none, now: at(1))
        let a2 = l.tick(one, none, now: at(31))
        eq(a1.sound, al.sound, "\(al.label): sound")
        eq(l.mayAutoOpen("sx", none, now: at(1)), al.bubbles, "\(al.label): bubble opens on its own")
        eq(!a2.banner.isEmpty, al.banners, "\(al.label): banner after 30 s")
        eq(Alerts(bits: al.bits), al, "\(al.label): stored bits read back")
    }
    var silentBanner = Calm(alerts: Alerts(bubbles: true, sound: false, banners: true))
    _ = silentBanner.tick([], none, now: at(0))
    let sb1 = silentBanner.tick(one, AlertContext(away: true), now: at(1))
    check(!sb1.sound && sb1.banner.map { $0.id } == ["x"], "banners without sound: a banner, no sound")
    eq(ShelfPrefs(defaults: UserDefaults(suiteName: "io.github.aaliismail.crewshelf.tests.empty.\(getpid())")!).alerts, .standard,
       "default alerts: bubbles and sound, no banners")
    // A level saved by the P1.5 build reads as the same switches.
    let legacy = "io.github.aaliismail.crewshelf.tests.legacy.\(getpid())"
    if let ld = UserDefaults(suiteName: legacy) {
        for (lv, want) in [(0, Alerts.off), (1, Alerts(bubbles: true, sound: false, banners: false)), (2, .standard), (3, .all)] {
            ld.set(lv, forKey: ShelfPrefs.legacyLevelKey)
            ld.removeObject(forKey: ShelfPrefs.alertsKey)
            eq(ShelfPrefs(defaults: ld).alerts, want, "old alertLevel \(lv) reads as \(want.label)")
        }
        ShelfPrefs(defaults: ld).alerts = Alerts(bubbles: false, sound: true, banners: true)
        eq(ShelfPrefs(defaults: ld).alerts, Alerts(bubbles: false, sound: true, banners: true), "new alerts read back")
        check(ld.object(forKey: ShelfPrefs.legacyLevelKey) == nil, "saving alerts drops the old level")
        dropSuite(legacy)
    }
    // The quiet controls survive a restart.
    let qs = "io.github.aaliismail.crewshelf.tests.quiet.\(getpid())"
    if let qd = UserDefaults(suiteName: qs) {
        let p = ShelfPrefs(defaults: qd)
        p.alerts = .all
        p.dndUntil = at(3600)
        p.muted = ["s1", "s2"]
        qd.synchronize()
        let back = ShelfPrefs(defaults: UserDefaults(suiteName: qs)!)
        eq(back.alerts, .all, "alerts read back")
        eq(back.dndUntil, at(3600), "DND end reads back")
        eq(back.muted, ["s1", "s2"], "mutes read back")
        p.muted = Set((0..<300).map { "m\($0)" })
        eq(back.muted.count, 200, "mutes are capped at 200")
        p.dndUntil = nil
        check(back.dndUntil == nil, "DND off clears it")
        dropSuite(qs)
    }

    // Do Not Disturb: silent until it expires, then normal again.
    var d = Calm(alerts: .all, dndUntil: at(3600))
    _ = d.tick([], none, now: at(0))
    let dn = d.tick(one, none, now: at(5))
    check(!dn.sound && dn.banner.isEmpty, "DND: no sound")
    eq(d.tick(one, none, now: at(100)).banner, [], "DND: no banner after 30 s")
    check(!d.mayAutoOpen("sx", none, now: at(100)), "DND: the bubble does not open on its own")
    check(!d.expireDND(at(3599)), "DND still on at 59:59")
    check(d.expireDND(at(3600)) && d.dndUntil == nil, "DND expires after 1 h")
    check(d.mayAutoOpen("sx", none, now: at(3600)), "after DND the bubble opens again")
    eq(d.tick(one + [ar("n", "sn")], none, now: at(3601)).sound, true, "after DND a new request sounds")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    let fmt = ISO8601DateFormatter()
    eq(nextMorning(after: fmt.date(from: "2026-11-12T21:30:00-06:00")!, calendar: cal), fmt.date(from: "2026-11-13T08:00:00-06:00")!,
       "until tomorrow, set at 9:30 pm: 8:00 next morning")
    eq(nextMorning(after: fmt.date(from: "2026-11-13T02:00:00-06:00")!, calendar: cal), fmt.date(from: "2026-11-13T08:00:00-06:00")!,
       "until tomorrow, set at 2 am: 8:00 this morning")

    // Mute this agent.
    var m = Calm(muted: ["sx"])
    _ = m.tick([], none, now: at(0))
    let mm = m.tick(one, none, now: at(1))
    check(!mm.sound, "muted agent: no sound")
    check(!m.mayAutoOpen("sx", none, now: at(1)), "muted agent: its bubble does not open on its own")
    eq(m.tick(one + [ar("o", "so")], none, now: at(2)).sound, true, "another agent still sounds")
    var mb = Calm(alerts: .all, muted: ["sx"])
    _ = mb.tick([], none, now: at(0))
    _ = mb.tick(one, none, now: at(1))
    eq(mb.tick(one, none, now: at(40)).banner, [], "muted agent: no banner")

    // Its own terminal tab is focused: no alert (unless the screen is locked).
    var f = Calm(alerts: .all)
    _ = f.tick([], none, now: at(0))
    let focused = AlertContext(focusedSessions: ["sx"])
    check(!f.tick(one, focused, now: at(1)).sound, "focused tab: no sound")
    check(!f.mayAutoOpen("sx", focused, now: at(1)), "focused tab: no bubble on its own")
    eq(f.tick(one, focused, now: at(40)).banner, [], "focused tab: no banner while you look at it")
    eq(f.tick(one, none, now: at(41)).banner.map { $0.id }, ["x"], "you left the tab with it unanswered: banner")
    check(f.mayAutoOpen("sx", AlertContext(away: true, focusedSessions: ["sx"]), now: at(1)), "locked screen: focus does not count")
    eq(focusedTty(cmuxTree: Data(fixture("cmux-tree.json").utf8)) ?? "", "ttys001", "cmux tree: the focused tab's tty")
    let notKey = fixture("cmux-tree.json").replacingOccurrences(of: "\"key\" : true", with: "\"key\" : false")
        .replacingOccurrences(of: "\"key\": true", with: "\"key\": false")
    check(focusedTty(cmuxTree: Data(notKey.utf8)) == nil, "no key cmux window: no focused tab")
    check(focusedTty(cmuxTree: Data("nope".utf8)) == nil, "garbage tree: none")

    // macOS Focus: no sound and no banner while it is on; bubbles still open. A request that waited through the
    // Focus gets its banner when the Focus ends.
    var fo = Calm(alerts: .all)
    _ = fo.tick([], none, now: at(0))
    let inFocus = AlertContext(focusMode: true)
    let fa = fo.tick(one, inFocus, now: at(1))
    check(!fa.sound && fa.banner.isEmpty, "Focus on: no sound")
    check(fo.mayAutoOpen("sx", inFocus, now: at(1)), "Focus on: the bubble still opens")
    eq(fo.tick(one, AlertContext(away: true, focusMode: true), now: at(40)).banner, [], "Focus on, screen locked, 40 s: still no banner")
    eq(fo.tick(one, none, now: at(41)).banner.map { $0.id }, ["x"], "Focus ended with it still waiting: banner then")

    // Collapsed is not a Calm input: a locked screen at the banner level banners at once, collapsed or not (the
    // shelf only stops bubbles). The app plays exactly what tick returns.
    var cl = Calm(alerts: .all)
    _ = cl.tick([], none, now: at(0))
    let la = cl.tick(one, AlertContext(away: true), now: at(1))
    check(la.sound && la.banner.map { $0.id } == ["x"], "screen locked at the banner level: one sound and the banner")
}

func focusTests() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    let fmt = ISO8601DateFormatter()
    func t(_ s: String) -> Date { fmt.date(from: s)! }
    let fri10 = t("2026-11-13T10:00:00-06:00"), sat10 = t("2026-11-14T10:00:00-06:00"), fri17 = t("2026-11-13T17:00:00-06:00")
    let noAssert = Data(#"{"data":[{"storeInvalidationRecords":[{"x":1}]}]}"#.utf8)
    let manual = Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}"#.utf8)
    func modes(_ trig: String) -> Data {
        Data(#"{"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"name":"Work"},"triggers":{"triggers":[\#(trig)]}},"com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb"},"triggers":{"triggers":[]}}}}]}"#.utf8)
    }
    let work = modes(#"{"class":"DNDModeConfigurationSmartTrigger","enabledSetting":0},{"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":2,"timePeriodStartTimeHour":8,"timePeriodStartTimeMinute":0,"timePeriodEndTimeHour":16,"timePeriodEndTimeMinute":0,"timePeriodWeekdays":31}"#)
    check(focusIsOn(assertions: manual, modes: nil, now: fri10, calendar: cal), "a Focus turned on by hand: on")
    check(!focusIsOn(assertions: noAssert, modes: modes(""), now: fri10, calendar: cal), "no assertion, no schedule: off")
    check(focusIsOn(assertions: noAssert, modes: work, now: fri10, calendar: cal), "Work scheduled 8-16 Mon-Fri, Friday 10:00: on")
    check(!focusIsOn(assertions: noAssert, modes: work, now: sat10, calendar: cal), "…Saturday 10:00: off")
    check(!focusIsOn(assertions: noAssert, modes: work, now: fri17, calendar: cal), "…Friday 17:00: off")
    let disabled = modes(#"{"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":1,"timePeriodStartTimeHour":8,"timePeriodEndTimeHour":16,"timePeriodWeekdays":127}"#)
    check(!focusIsOn(assertions: noAssert, modes: disabled, now: fri10, calendar: cal), "a schedule that is turned off: off")
    let sleep = modes(#"{"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":2,"timePeriodStartTimeHour":22,"timePeriodStartTimeMinute":30,"timePeriodEndTimeHour":7,"timePeriodEndTimeMinute":0,"timePeriodWeekdays":16}"#)
    check(focusIsOn(assertions: noAssert, modes: sleep, now: t("2026-11-13T23:00:00-06:00"), calendar: cal), "Sleep 22:30-7:00 on Fridays, Friday 23:00: on")
    check(focusIsOn(assertions: noAssert, modes: sleep, now: t("2026-11-14T03:00:00-06:00"), calendar: cal), "…Saturday 3:00 (Friday's night): on")
    check(!focusIsOn(assertions: noAssert, modes: sleep, now: t("2026-11-13T03:00:00-06:00"), calendar: cal), "…Friday 3:00 (Thursday's night, not scheduled): off")
    check(!focusIsOn(assertions: Data("nope".utf8), modes: Data("{".utf8), now: fri10, calendar: cal), "unreadable files: off")
    check(!focusIsOn(assertions: nil, modes: nil, now: fri10, calendar: cal), "no files: off")
}

func calmBubbleTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // Counts: only requests Crewshelf can answer.
    var np = mk("np", .blocked)                         // no plugin, waiting in its terminal
    np.hooked = false
    var term = mk("tm", .blocked)                       // hooked, but handed to the terminal
    term.hooked = true
    let sessions = [req("a", "r-a", at: 10), req("b", "r-b", at: 20), np, term, mk("w", .working)]
    var q = BubbleQueue()
    q.update(sessions, now: at(0)) { _ in nil }
    eq(q.needsYouCount(sessions), 2, "count: only requests that can be answered in Crewshelf")
    eq(q.waiting(sessions).map { $0.sessionId }, ["b"], "orange !: only answerable requests whose bubble is closed")
    check(BubbleQueue.waitsElsewhere(np) && BubbleQueue.waitsElsewhere(term), "no plugin / handed to the terminal: dim marker")
    check(!BubbleQueue.waitsElsewhere(req("a", "r-a", at: 10)) && !BubbleQueue.waitsElsewhere(mk("w", .working)), "others: no dim marker")
    var onlyNp = BubbleQueue()
    onlyNp.update([np, term], now: at(0)) { _ in nil }
    check(onlyNp.open == nil && onlyNp.needsYouCount([np, term]) == 0, "no-plugin waits never auto-open and count 0")

    // Holds: muted / focused / Off / DND keep a request from opening on its own; others still open.
    var h = BubbleQueue()
    h.holdBack = ["a"]
    h.update(sessions, now: at(0)) { _ in nil }
    eq(h.open?.sessionId ?? "", "b", "a held-back agent is skipped; the next request opens")
    var off = BubbleQueue()
    off.autoOpenEnabled = false
    off.update(sessions, now: at(0)) { _ in nil }
    check(off.open == nil, "alerts Off or DND: nothing opens on its own")
    off.tap(req("a", "r-a", at: 10), now: at(1))
    eq(off.open?.sessionId ?? "", "a", "…but a click still opens it")

    // Done fades after 10 s unless hovered; clicking brings it back.
    var hk = mk("h", .idle)
    hk.hooked = true; hk.doneKey = "h|stop|1"; hk.doneText = "Wrote the plan."
    var d = BubbleQueue()
    d.update([hk], now: at(0)) { $0.doneText }
    d.tap(hk, now: at(1))
    eq(d.open?.kind, .finished, "click on the check: Done")
    check(!d.fadeDone(now: at(10.9), hovering: false) && d.open != nil, "Done still open at 9.9 s")
    check(d.fadeDone(now: at(11), hovering: false) && d.open == nil, "Done fades after 10 s")
    d.update([hk], now: at(12)) { $0.doneText }
    d.tap(hk, now: at(13))
    eq(d.open?.kind, .finished, "clicking the character brings Done back")
    eq(d.open?.summary ?? "", "Wrote the plan.", "with the same message")
    for s in stride(from: 14.0, through: 40.0, by: 1) { _ = d.fadeDone(now: at(s), hovering: true) }
    check(d.open != nil, "hovered: Done stays (27 s)")
    check(!d.fadeDone(now: at(49), hovering: false), "pointer left at 40 s: still open at 49 s")
    check(d.fadeDone(now: at(50), hovering: false), "…and fades 10 s after the pointer left")
    var working = hk
    working.state = .working
    d.update([working], now: at(51)) { _ in nil }
    d.tap(working, now: at(52))
    eq(d.open?.kind, .manual, "once it works again, a click shows its steps, not the old Done")
    var pr = BubbleQueue()
    pr.update([req("a", "r-a", at: 10)], now: at(0)) { _ in nil }
    check(!pr.fadeDone(now: at(100), hovering: false) && pr.open != nil, "a request bubble never fades")

    // The check mark stays until it is clicked or the agent works again: away for an hour, it is still there.
    var hk2 = mk("h2", .idle)
    hk2.hooked = true; hk2.doneKey = "h2|stop|1"; hk2.doneText = "Shipped it."
    var dm = BubbleQueue()
    dm.update([hk2], now: at(0)) { $0.doneText }
    dm.update([hk2], now: at(3600)) { $0.doneText }
    check(dm.hasCheck("h2"), "an hour later the check is still there")
    dm.click(hk2, sessions: [hk2], now: at(3601))
    eq(dm.open?.kind, .finished, "clicking it an hour later shows Done, not the generic bubble")
    eq(dm.open?.summary ?? "", "Shipped it.", "with its message")
    var hk3 = hk2
    hk3.state = .working
    var dw = BubbleQueue()
    dw.update([hk2], now: at(0)) { $0.doneText }
    dw.update([hk3], now: at(5)) { _ in nil }
    check(!dw.hasCheck("h2"), "working again: the check goes")

    // Agents without the plugin: counted dimly on the collapsed shelf and alerted like any wait (sound, banner),
    // but not one you handed to the terminal yourself.
    var npw = mk("np", .blocked)
    npw.hooked = false; npw.needs = "Allow rm -rf build?"
    var handed = mk("tm", .blocked)
    handed.hooked = true
    let hookedReq = req("a", "r-a", at: 10)
    let mixed = [hookedReq, npw, handed, mk("w", .working)]
    var cq = BubbleQueue(collapsed: true)
    cq.update(mixed, now: at(0)) { _ in nil }
    eq(cq.needsYouCount(mixed), 1, "collapsed: the orange count is the one request answerable here")
    eq(cq.elsewhereCount(mixed), 2, "collapsed: a dim count shows the two waiting in their terminals")
    let pend = PendingRequest(id: "r-a", sessionId: "a", kind: .permission, event: "PermissionRequest", toolName: "Bash", cwd: "/p",
                              permissionMode: nil, createdAt: at(10), deadline: at(600),
                              preview: PermissionPreview(title: "Bash", subtitle: "ls", body: "ls", style: .code), questions: [])
    let alerts = alertRequests(mixed, pending: ["a": [pend]])
    eq(alerts.map { $0.sessionId }, ["a", "np"], "alerts: the hook request and the no-plugin wait, not the hand-off")
    eq(alerts.last?.summary ?? "", "Allow rm -rf build?", "the no-plugin alert says what it waits for")
    var nc = Calm(alerts: .all)
    _ = nc.tick([], AlertContext(), now: at(0))
    check(nc.tick(alertRequests([npw], pending: [:]), AlertContext(), now: at(1)).sound, "a no-plugin agent that starts waiting sounds")

    // Clicking the collapsed shelf's character expands the shelf and shows its request; nothing is dismissed.
    let one = req("A", "req1", at: 10)
    var c1 = BubbleQueue(collapsed: true)
    c1.update([one], now: at(0)) { _ in nil }
    check(c1.open == nil, "collapsed: nothing open")
    c1.click(one, sessions: [one], now: at(1))
    check(!c1.collapsed, "a click on the collapsed character expands the shelf")
    eq(c1.open?.sessionId ?? "", "A", "…and shows that character's request")
    eq(c1.dismissed, [], "…without dismissing it")
    c1.update([one], now: at(3)) { _ in nil }
    eq(c1.open?.sessionId ?? "", "A", "the next poll keeps it open")

    // Double-click on a character: collapses (or expands), never dismisses.
    var c2 = BubbleQueue()
    c2.update([one], now: at(0)) { _ in nil }
    eq(c2.open?.sessionId ?? "", "A", "its request is open")
    c2.click(one, count: 1, sessions: [one], now: at(1))
    c2.click(one, count: 2, sessions: [one], now: at(1.2))
    check(c2.collapsed && c2.open == nil, "double-click on the open request's character: collapsed")
    eq(c2.dismissed, [], "…and the request was not dismissed")
    c2.click(one, count: 1, sessions: [one], now: at(5))
    c2.click(one, count: 2, sessions: [one], now: at(5.2))
    check(!c2.collapsed, "double-click on the collapsed character: expanded")
    eq(c2.open?.sessionId ?? "", "A", "…with its request open again")
    eq(c2.dismissed, [], "…still not dismissed")
    let two = req("B", "req2", at: 20)
    var c3 = BubbleQueue()
    c3.update([one, two], now: at(0)) { _ in nil }
    c3.click(two, count: 1, sessions: [one, two], now: at(1))
    c3.click(two, count: 2, sessions: [one, two], now: at(1.3))
    check(c3.collapsed && c3.dismissed.isEmpty, "double-click on a waiting character: collapsed, nothing dismissed")
    c3.collapse(false, sessions: [one, two], now: at(2))
    eq(c3.open?.sessionId ?? "", "A", "expanded again: the oldest request opens as before")
    var c4 = BubbleQueue()
    c4.update([one], now: at(0)) { _ in nil }
    c4.click(one, count: 1, sessions: [one], now: at(1))
    c4.click(one, count: 2, sessions: [one], now: at(3), doubleClickInterval: 0.5)
    check(!c4.collapsed, "a second click outside the double-click time is a click, not a collapse")
}

/// True when this shell can't bind a Unix socket (a sandboxed run): socket tests are skipped, not failed.
let sandboxed: Bool = {
    if ProcessInfo.processInfo.environment["CREWSHELF_FORCE_SOCKET_TESTS"] == "1" { return false }
    let path = tmpBase + "hh-probe-\(getpid()).sock"
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { close(fd); unlink(path) }
    guard var a = makeAddr(path) else { return true }
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    return r != 0
}()

func runCalmTests() {
    placementTests()
    calmTests()
    calmBubbleTests()
    focusTests()
}
