import AppKit
import ServiceManagement
import SwiftUI

final class CrewshelfPanel: NSPanel {
    var keyable = true
    /// Click count of the latest left click in any Crewshelf window. SwiftUI's tap gesture does not say whether a
    /// tap is the second click of a double-click; the character's tap reads it here.
    static var lastClickCount = 1
    override var canBecomeKey: Bool { keyable }    // the bubble only, so its reply field can take typing
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp { CrewshelfPanel.lastClickCount = max(1, event.clickCount) }
        super.sendEvent(event)
    }
}

/// Clicks land on the first try even though Crewshelf is never the active app. A right-click opens the shelf menu.
final class CrewshelfHostingView<V: View>: NSHostingView<V> {
    var contextMenu: ((NSPoint) -> NSMenu?)?
    var captureMenu: ((NSMenu) -> Void)?       // test control: take the menu instead of popping it up
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        guard let make = contextMenu, let m = make(convert(event.locationInWindow, from: nil)) else {
            return super.rightMouseDown(with: event)
        }
        if let take = captureMenu { return take(m) }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
}

func makePanel() -> CrewshelfPanel {
    let p = CrewshelfPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    p.isFloatingPanel = true
    p.level = .floating
    p.collectionBehavior = panelBehavior
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false      // SwiftUI draws the shadows; a window shadow on a clear panel bands
    p.isMovable = false      // moved by ShelfDrag, so a drag that starts on a character never moves it
    return p
}

/// Displays as the placement code sees them: a stable UUID per display and its visible frame.
func currentDisplays() -> [DisplayInfo] {
    NSScreen.screens.enumerated().map { i, sc in
        let num = (sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let id = CGDisplayCreateUUIDFromDisplayID(num).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            ?? "display-\(num)"
        return DisplayInfo(id: id, frame: sc.visibleFrame, isMain: i == 0)
    }
}

/// A window's content, or nothing at all while nobody can see any of it (screen locked, displays asleep). With no
/// view observing the model, its changes then cost no SwiftUI update and no layout; the content is put back, as it
/// was (the model holds all its state), when you return.
struct Gated<Content: View>: View {
    var content: Content?
    var body: some View {
        if let c = content { c }
    }
}

/// Moving faces render at a capture's scale while it runs (called on the main thread).
func setCaptureScale(_ s: CGFloat?) { MainActor.assumeIsolated { FaceView.captureScale = s } }

/// `Crewshelf --demo`: fake agents for screenshots (see Demo.swift).
let isDemo = CommandLine.arguments.contains("--demo")

/// Crewshelf's windows join every Space and sit over full-screen apps, so the shelf is there whichever Space is active.
let panelBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CrewshelfModel(demo: isDemo)
    var recorder: GifRecorder?
    var shelfPanel: CrewshelfPanel!
    var bubblePanel: CrewshelfPanel!
    var shelfHost: CrewshelfHostingView<Gated<ShelfRoot>>!
    var bubbleHost: CrewshelfHostingView<Gated<BubbleRoot>>!
    var paused = false                   // both windows' content is gated off (see Gated)
    var spot: ShelfSpot?                 // saved place; nil until the first drop (bottom-right of the main screen)
    var drag: (mouse: NSPoint, origin: NSPoint)?
    lazy var menus = ShelfMenus(model: model)
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        // The socket before any window: a second copy quits here, with no shelf shown and app-path untouched.
        guard model.claimSocket() else { exit(0) }
        shelfPanel = makePanel()
        shelfPanel.keyable = false
        bubblePanel = makePanel()
        shelfHost = CrewshelfHostingView(rootView: Gated(content: ShelfRoot(model: model)))
        bubbleHost = CrewshelfHostingView(rootView: Gated(content: BubbleRoot(model: model)))
        shelfPanel.contentView = shelfHost
        bubblePanel.contentView = bubbleHost
        shelfHost.contextMenu = { [weak self] p in self?.menu(at: p) }
        spot = model.prefs.placement.current
        menus.corner = { [weak self] in self.flatMap { effectiveSpot($0.spot, displays: currentDisplays())?.corner } }
        menus.setCorner = { [weak self] h, v in self?.placeCorner(h, v) }
        model.onLayout = { [weak self] in DispatchQueue.main.async { self?.layout() } }
        model.onDrag = { [weak self] phase, p in self?.dragged(phase, windowPoint: p) }
        model.onControl = { [weak self] obj in self?.control(obj) }
        layout()
        shelfPanel.orderFrontRegardless()
        if isDemo {
            FileHandle.standardError.write("crewshelf: demo mode (fake agents only), control socket \(crewshelfSocketPath())\n".data(using: .utf8)!)
        }
        model.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
        // Locked screen, displays asleep, shelf covered: stop animating until it shows again.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: shelfPanel, queue: .main) { [weak self] _ in self?.updateOnScreen() }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            // After the model's own observer has recorded the sleep or wake (observer order is not guaranteed).
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateOnScreen() }
            }
        }
        for n in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(forName: .init(n), object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.updateOnScreen() }
            }
        }
        updateOnScreen()
        // `kill`, `pkill` and Ctrl-C quit like the menu's Quit, so the socket is removed (a demo's too).
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ note: Notification) { model.stop() }

    func updateOnScreen() {
        // A demo always animates: it is recorded for screenshots and the GIF, locked screen or not.
        // CREWSHELF_FORCE_ON_SCREEN=1 does the same for a test instance (CPU measurements on a locked Mac).
        let forced = isDemo || ProcessInfo.processInfo.environment["CREWSHELF_FORCE_ON_SCREEN"] == "1"
        let away = !forced && model.away()
        let on = forced || (shelfPanel.occlusionState.contains(.visible) && !away)
        if model.onScreen != on {
            model.onScreen = on
            if on { model.now = Date() }
        }
        setPaused(away)
    }

    /// Locked or asleep: nothing of Crewshelf can be seen, so its windows drop their content (alerts, hooks and polling
    /// go on). A covered shelf only stops animating: its bubble may still be in view.
    func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        shelfHost.rootView = Gated(content: p ? nil : ShelfRoot(model: model))
        bubbleHost.rootView = Gated(content: p ? nil : BubbleRoot(model: model))
        if !p { DispatchQueue.main.async { [weak self] in self?.layout() } }
    }

    // MARK: layout

    /// The shelf at its saved spot (sized to content, growing toward the screen's center), and the bubble on
    /// the side of it that faces the center, clamped to the screen.
    func layout() {
        updateOnScreen()
        guard !paused else { return }       // laid out again when the content comes back
        shelfHost.layoutSubtreeIfNeeded()
        let size = shelfHost.fittingSize
        let displays = currentDisplays()
        var frame: NSRect
        let side: ShelfSpot
        if drag != nil {             // mid-drag the pointer owns the position; only the size follows content
            let f = shelfPanel.frame
            frame = NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height)
            side = dropSpot(frame, displays: displays) ?? .corner("")
        } else {
            guard let placed = shelfFrame(spot: spot, size: size, displays: displays) else { return }
            frame = placed.frame
            side = placed.spot
        }
        if model.shelfSide.h != side.h || model.shelfSide.v != side.v { model.shelfSide = (side.h, side.v) }
        if shelfPanel.frame != frame { shelfPanel.setFrame(frame, display: true) }
        layoutBubble()
    }

    func layoutBubble() {
        guard !paused else { return }
        let agentBubble = model.collapsed ? nil : model.bubbles.open.flatMap { model.session($0.sessionId) != nil ? $0 : nil }
        guard agentBubble != nil || model.notice != nil else {
            if bubblePanel.isVisible { bubblePanel.orderOut(nil) }
            if bubblePanel.isKeyWindow { bubblePanel.resignKey() }
            if model.bubbleCut != 0 { model.bubbleCut = 0 }
            return
        }
        bubbleHost.layoutSubtreeIfNeeded()
        let size = bubbleHost.fittingSize
        let shelf = shelfPanel.frame
        // The display the shelf is on (its center, else the one it overlaps most), so a shelf dragged to another
        // display opens its bubble there.
        let screen = display(for: shelf, in: currentDisplays())?.frame ?? shelf
        let anchor = agentBubble.flatMap { model.charFrames[$0.sessionId] }.map { shelf.minX + $0.midX } ?? shelf.midX
        let pl = bubblePlacement(shelf: shelf, anchorX: anchor, size: size, screen: screen)
        // Taller than the room beside the shelf: shorten the scrolling part and lay out again, so the bubble never
        // covers the shelf. More room again (the shelf moved, the content shrank): give the height back.
        let cut = bubbleCut(current: model.bubbleCut, height: size.height, room: pl.room, maxCut: maxBubbleCut)
        if abs(cut - model.bubbleCut) >= 1 {
            model.bubbleCut = cut
            DispatchQueue.main.async { [weak self] in self?.layoutBubble() }
        }
        // The tail sits inside the 8 pt shadow padding of the bubble window.
        let tail = BubbleTail(x: pl.tailX - 8, top: pl.below)
        if model.bubbleTail != tail { model.bubbleTail = tail }
        if bubblePanel.frame != pl.frame { bubblePanel.setFrame(pl.frame, display: true) }
        if !bubblePanel.isVisible { bubblePanel.orderFrontRegardless() }
    }

    // MARK: dragging the shelf

    /// `windowPoint` is the pointer in the shelf window (SwiftUI global space, y down). Converted to the screen
    /// with the window's current frame, so moving the window under the pointer does not feed back.
    func dragged(_ phase: DragPhase, windowPoint p: CGPoint) {
        let f = shelfPanel.frame
        let mouse = NSPoint(x: f.minX + p.x, y: f.maxY - p.y)
        switch phase {
        case .began:
            drag = (mouse, f.origin)
        case .moved:
            if drag == nil { drag = (mouse, f.origin) }
            guard let d = drag else { return }
            shelfPanel.setFrameOrigin(NSPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
            layoutBubble()
        case .ended:
            if let d = drag {
                shelfPanel.setFrameOrigin(NSPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
            }
            drag = nil
            if let s = dropSpot(shelfPanel.frame, displays: currentDisplays()) {
                spot = s
                model.prefs.placement.save(s)
            }
            layout()
        }
    }

    /// Settings > Corner: snap into that corner of the display the shelf is on now (a dragged spot is replaced).
    func placeCorner(_ h: HSide, _ v: VSide) {
        guard let d = display(for: shelfPanel.frame, in: currentDisplays()) else { return }
        let s = ShelfSpot.corner(d.id, h, v)
        spot = s
        model.prefs.placement.save(s)
        layout()
    }

    // MARK: right-click menu

    func menu(at p: NSPoint) -> NSMenu {
        let agent = model.charFrames.first { $0.value.contains(p) }.flatMap { model.session($0.key) }
        return menus.build(agent: agent)
    }

    // MARK: test control (`Crewshelf --ctl layout | click | drag | menu | snapshot`)

    func screenRect(_ r: CGRect, in w: NSWindow) -> CGRect {
        CGRect(x: w.frame.minX + r.minX, y: w.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func control(_ obj: [String: Any]) -> [String: Any]? {
        let op = obj["op"] as? String ?? ""
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        func json(_ r: CGRect) -> [String: Double] {      // AppKit frame plus the CG (top-left origin) center
            ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height, "cgx": r.midX, "cgy": mainH - r.midY].mapValues { Double($0) }
        }
        switch op {
        case "layout":
            var probes: [String: Any] = [:]
            for (k, r) in model.probes { probes[k] = json(screenRect(r, in: bubblePanel)) }
            for (k, r) in model.shelfProbes { probes[k] = json(screenRect(r, in: shelfPanel)) }
            for (k, r) in model.charFrames { probes["char:" + k] = json(screenRect(r, in: shelfPanel)) }
            var out: [String: Any] = ["ok": true, "shelf": json(shelfPanel.frame), "collapsed": model.collapsed]
            out["bubble_visible"] = bubblePanel.isVisible
            out["probes"] = probes
            out["shelf_window"] = shelfPanel.windowNumber
            out["bubble_window"] = bubblePanel.windowNumber
            out["pid"] = Int(getpid())
            let al = model.calm.alerts
            out["alerts"] = ["bubbles": al.bubbles, "sound": al.sound, "banners": al.banners, "label": al.label]
            out["dnd_until"] = model.calm.dndUntil.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
            out["muted"] = Array(model.calm.muted).sorted()
            out["spot"] = spotText
            out["needs_you"] = model.bubbles.needsYouCount(model.shelf)
            out["waits_elsewhere"] = model.bubbles.elsewhereCount(model.shelf)
            out["bubble_cut"] = Double(model.bubbleCut)
            out["chimes"] = model.notifier.chimes
            out["banners"] = model.notifier.banners
            out["checks"] = model.shelf.filter { model.bubbles.hasCheck($0.sessionId) }.map { $0.sessionId }
            out["orange_bang"] = model.bubbles.waiting(model.shelf).map { $0.sessionId }
            out["dim_marker"] = model.shelf.filter { BubbleQueue.waitsElsewhere($0) }.map { $0.sessionId }
            out["shown"] = model.shownShelf.map { $0.sessionId }
            out["hide_idle"] = model.hideIdle
            out["notice"] = model.notice.map { "\($0)" } ?? NSNull()
            out["demo"] = model.demo != nil
            out["on_screen"] = model.onScreen
            out["paused"] = paused
            out["all_spaces"] = shelfPanel.collectionBehavior.contains(.canJoinAllSpaces) && bubblePanel.collectionBehavior.contains(.canJoinAllSpaces)
            out["display"] = display(for: shelfPanel.frame, in: currentDisplays())?.id ?? NSNull()
            out["login_item"] = LoginItem.statusText
            out["login_allowed"] = LoginItem.allowed
            if bubblePanel.isVisible { out["bubble"] = json(bubblePanel.frame) }
            if let o = model.bubbles.open { out["open"] = ["session_id": o.sessionId, "kind": ["prompt", "finished", "manual"][o.kind.rawValue]] }
            return out
        case "click", "doubleclick", "drag":
            guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return ["ok": false, "error": "need x y (CG coords)"] }
            let p = NSPoint(x: x, y: mainH - y)
            if op == "drag" {
                guard let x2 = obj["x2"] as? Double, let y2 = obj["y2"] as? Double else { return ["ok": false, "error": "need x2 y2"] }
                return synthDrag(from: p, to: NSPoint(x: x2, y: mainH - y2))
            }
            return synthClick(p, count: op == "doubleclick" ? 2 : 1)
        case "rightclick":
            guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return ["ok": false, "error": "need x y (CG coords)"] }
            return synthRightClick(NSPoint(x: x, y: mainH - y))
        case "menu":
            let agent = (obj["session"] as? String).flatMap { model.engine.find($0, in: model.shelf) }
            let m = menus.build(agent: agent)
            if let path = obj["pick"] as? String {
                guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
                guard pick(path.components(separatedBy: "/"), in: m) else { return ["ok": false, "error": "no menu item \(path)"] }
                return ["ok": true, "picked": path, "items": describe(menus.build(agent: agent))]
            }
            return ["ok": true, "items": describe(m)]
        case "plan":
            // Which terminal an agent runs in and the steps Open takes ("plan" runs nothing).
            guard let key = obj["session"] as? String, let s = model.engine.find(key, in: model.shelf) else {
                return ["ok": false, "error": "no session matching \(obj["session"] as? String ?? "")"]
            }
            var t = s.kind == .background ? TerminalEnv(pid: s.hostPid) : (s.terminal ?? TerminalEnv(pid: s.pid))
            if t.pid == nil { t.pid = s.pid }
            if t.tty == nil, let p = t.pid { t.tty = procEntry(p)?.tty }
            let f = model.engine.hostFacts(t)
            let plan = openPlan(t, f, cwd: s.cwd)
            return ["ok": true, "kind": plan.kind.rawValue, "note": plan.note ?? NSNull(), "steps": plan.steps.map { "\($0)" },
                    "vars": t.vars, "tty": t.tty ?? NSNull(), "pid": t.pid ?? NSNull(),
                    "owner": f.owner?.bundleId ?? NSNull(), "under_tmux": f.underTmux]
        case "screen":
            guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            switch obj["which"] as? String {
            case "away": model.awayOverride = true
            case "back": model.awayOverride = false
            default: model.awayOverride = nil
            }
            updateOnScreen()
            return ["ok": true, "paused": paused, "on_screen": model.onScreen]
        case "demo":
            guard let d = model.demo else { return ["ok": false, "error": "not in demo mode"] }
            if let f = obj["freeze"] as? Bool { d.frozen = f }
            return ["ok": true, "frozen": d.frozen, "waiting": d.waitingRequests]
        case "notice":
            guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            let n: Notice?
            switch obj["which"] as? String {
            case "install": n = .install
            case "connected": n = .connected
            case "move": n = .moveToApplications(Bundle.main.bundlePath)
            case "approval": n = .loginApproval
            default: n = nil
            }
            model.showNotice(n)
            return ["ok": true]
        case "record":
            guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            guard let path = obj["path"] as? String else { return ["ok": false, "error": "need path"] }
            guard recorder == nil else { return ["ok": false, "error": "already recording"] }
            let seconds = obj["seconds"] as? Double ?? 10, fps = obj["fps"] as? Double ?? 8, scale = obj["scale"] as? Double ?? 1
            let region = recordRegion()
            let rec = GifRecorder(path: path, frames: Int(seconds * fps), fps: fps)
            recorder = rec
            setCaptureScale(CGFloat(scale))
            rec.start { [weak self] in self?.composite(region: region, scale: CGFloat(scale), backdrop: true) } done: { [weak self] ok in
                setCaptureScale(nil)
                self?.recorder = nil
                FileHandle.standardError.write("crewshelf: recorded \(path) ok=\(ok)\n".data(using: .utf8)!)
            }
            return ["ok": true, "recording": path, "frames": Int(seconds * fps)]
        case "snapshot":
            // The bubble shows full commands and diffs, and the path is any file: test instances only.
            guard model.hooks.allowControlDecisions else { return ["ok": false, "error": DecideError.controlOff.rawValue] }
            guard let path = obj["path"] as? String else { return ["ok": false, "error": "need path"] }
            let which = obj["window"] as? String ?? "shelf"
            if which == "both" {
                let scale = CGFloat(obj["scale"] as? Double ?? 2)
                setCaptureScale(scale)
                defer { setCaptureScale(nil) }
                guard let rep = composite(region: nil, scale: scale, backdrop: true),
                      let png = rep.representation(using: .png, properties: [:]),
                      (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return ["ok": false, "error": "write failed"] }
                return ["ok": true, "path": path, "w": rep.pixelsWide, "h": rep.pixelsHigh]
            }
            let v: NSView = which == "bubble" ? bubbleHost : shelfHost
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return ["ok": false, "error": "no image"] }
            v.cacheDisplay(in: v.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return ["ok": false, "error": "write failed"] }
            return ["ok": true, "path": path]
        default:
            return nil
        }
    }

    /// A mouse event at a screen point, sent through AppKit the way the window server delivers one: to the
    /// window under the point, with the point in that window's coordinates.
    @discardableResult
    func post(_ type: NSEvent.EventType, at p: NSPoint, count: Int = 1, to target: NSWindow? = nil) -> NSWindow? {
        let w = target ?? [bubblePanel, shelfPanel].compactMap { $0 }.first { $0.isVisible && $0.frame.contains(p) }
        guard let win = w, let e = NSEvent.mouseEvent(with: type, location: win.convertPoint(fromScreen: p), modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) else { return nil }
        win.sendEvent(e)
        return win
    }

    func synthClick(_ p: NSPoint, count: Int) -> [String: Any] {
        for n in 1...count {
            guard let w = post(.leftMouseDown, at: p, count: n) else { return ["ok": false, "error": "no Crewshelf window at that point"] }
            post(.leftMouseUp, at: p, count: n, to: w)
        }
        return ["ok": true, "window": w(p)]
    }

    /// A right-click through AppKit, down to the shelf view's rightMouseDown. The menu it would pop up is taken
    /// instead (a popped-up menu runs its own modal loop, which a test can't drive without Accessibility).
    func synthRightClick(_ p: NSPoint) -> [String: Any] {
        var items: [[String: Any]] = []
        shelfHost.captureMenu = { [weak self] m in items = self?.describe(m) ?? [] }
        defer { shelfHost.captureMenu = nil }
        guard let win = post(.rightMouseDown, at: p) else { return ["ok": false, "error": "no Crewshelf window at that point"] }
        post(.rightMouseUp, at: p, to: win)
        return ["ok": !items.isEmpty, "menu": items]
    }

    func w(_ p: NSPoint) -> String { bubblePanel.isVisible && bubblePanel.frame.contains(p) ? "bubble" : "shelf" }

    /// mouseDown, a dozen drags, mouseUp: all to the window that took the mouseDown, as AppKit does.
    func synthDrag(from a: NSPoint, to b: NSPoint) -> [String: Any] {
        guard let win = post(.leftMouseDown, at: a) else { return ["ok": false, "error": "no Crewshelf window at that point"] }
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, at: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), to: win)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        post(.leftMouseUp, at: b, to: win)
        return ["ok": true, "spot": spotText,
                "shelf": ["x": Double(shelfPanel.frame.minX), "y": Double(shelfPanel.frame.minY)]]
    }

    // MARK: screenshots and the GIF (test control only)

    /// One window's content at `scale`.
    func image(of v: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        let b = v.bounds
        guard b.width > 0, b.height > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale),
                                                                   pixelsHigh: Int(b.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                                   bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        v.cacheDisplay(in: b, to: rep)
        return rep
    }

    /// The shelf and the bubble as they sit on screen, drawn into one image over a dark backdrop. `region` fixes
    /// the canvas (screen coordinates) so every frame of a GIF lines up; nil means just around the windows.
    func composite(region: NSRect?, scale: CGFloat, backdrop: Bool) -> NSBitmapImageRep? {
        let wins: [(NSWindow, NSView)] = [(shelfPanel, shelfHost), (bubblePanel, bubbleHost)].filter { $0.0.isVisible }
        let around = wins.map { $0.0.frame }.reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -16, dy: -16)
        let canvas = (region ?? around).integral
        guard canvas.width > 0, canvas.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = canvas.size             // points: set before the context is made, so it draws at `scale`
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        if backdrop {
            NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1),
                       ending: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))?
                .draw(in: NSRect(origin: .zero, size: canvas.size), angle: -90)
        }
        for (w, v) in wins {
            guard let img = image(of: v, scale: scale) else { continue }
            img.draw(in: NSRect(x: w.frame.minX - canvas.minX, y: w.frame.minY - canvas.minY, width: w.frame.width, height: w.frame.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The GIF's fixed canvas: the shelf plus the room above (or below) it where bubbles open, on its display.
    func recordRegion() -> NSRect {
        let s = shelfPanel.frame
        let screen = display(for: s, in: currentDisplays())?.frame ?? s
        let w = max(s.width, bubbleWidth + 40) + 24
        let x = s.midX >= screen.midX ? s.maxX + 12 - w : s.minX - 12
        let room: CGFloat = 360
        let y = s.midY < screen.midY ? s.minY - 12 : s.minY - room
        return NSRect(x: x, y: y, width: w, height: s.height + room + 12).intersection(screen.insetBy(dx: -12, dy: -12))
    }

    var spotText: String {
        guard let s = spot else { return "default (bottom-right of the main screen)" }
        return "\(s.display) \(s.h.rawValue)/\(s.v.rawValue) dx=\(Int(s.dx)) dy=\(Int(s.dy))"
    }

    func describe(_ m: NSMenu) -> [[String: Any]] {
        m.items.filter { !$0.isSeparatorItem }.map { i in
            var d: [String: Any] = ["title": i.title, "on": i.state == .on, "enabled": i.isEnabled]
            if let sub = i.submenu { d["items"] = describe(sub) }
            return d
        }
    }

    func pick(_ path: [String], in m: NSMenu) -> Bool {
        guard let first = path.first, let i = m.items.firstIndex(where: { $0.title == first }) else { return false }
        if path.count > 1, let sub = m.items[i].submenu { return pick(Array(path.dropFirst()), in: sub) }
        guard m.items[i].isEnabled else { return false }
        m.performActionForItem(at: i)
        return true
    }
}

// MARK: command line

func arg(after flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

@MainActor func cli() -> Int32? {
    let a = CommandLine.arguments
    if a.contains("--remove-login-item") {     // uninstall.sh: this copy's login item, if it has one
        guard [.enabled, .requiresApproval].contains(LoginItem.status) else { print("no login item"); return 0 }
        do { try SMAppService.mainApp.unregister(); print("login item removed"); return 0 }
        catch { print("could not remove the login item: \(error.localizedDescription)"); return 1 }
    }
    let engine = Engine()
    if a.contains("--dump") {
        print(dump(engine: engine, steps: Int(arg(after: "--steps") ?? "") ?? 15))
        return 0
    }
    if a.contains("--notify-test") {
        let n = Notifier()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        n.notify(title: "Crewshelf", body: "Notification test. Agents that need you will show up like this.")
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        print("sent via \(n.method)")
        return 0
    }
    if a.contains("--ctl") { return ctl(Array(a.drop(while: { $0 != "--ctl" }).dropFirst())) }
    for flag in ["--jump", "--done"] where a.contains(flag) {
        guard let key = arg(after: flag) else { print("usage: Crewshelf \(flag) <session>"); return 2 }
        let sessions = engine.snapshot()
        guard let s = engine.find(key, in: sessions) else { print("no session matching \(key)"); return 1 }
        let r = flag == "--jump" ? engine.jump(s) : engine.done(s)
        print((r.ok ? "ok: " : "failed: ") + r.message)
        return r.ok ? 0 : 1
    }
    return nil
}

/// `Crewshelf --ctl list | decide <id> allow|deny|terminal [message] | answer <id> '<json>'`: talks to the running
/// app over its socket, which calls the same HookCenter.decide the bubble's buttons call.
func ctl(_ args: [String]) -> Int32 {
    let usage = """
        usage: Crewshelf --ctl list | decide <id> allow|deny|terminal [message] | answer <id> '{"<question>":"<label>"}'
                          | tap <session> | layout | menu [<session> ["Alerts/Sound"]] | snapshot <png> [shelf|bubble]
                          | click|doubleclick|rightclick <x> <y> | drag <x> <y> <x2> <y2>   (screen points, top-left origin)
                          | plan <session> | open <session> | demo [freeze|run] | notice install|connected|move|approval|none
                          | screen away|back|real   (pretend the screen is locked / unlocked, or stop pretending)
                          | snapshot <png> both [scale] | record <gif> [seconds] [fps] [scale]
        decide, answer, tap, open, click, drag, menu picks, notice, screen, snapshot and record need an app started with CREWSHELF_TEST_CONTROL=1.
        """
    var req: [String: Any] = ["v": hookWireVersion, "kind": "ctl"]
    switch args.first {
    case "list":
        req["op"] = "list"
    case "decide" where args.count >= 3:
        req["op"] = "decide"; req["id"] = args[1]; req["decision"] = args[2]
        if args.count >= 4 { req["message"] = args[3] }
    case "answer" where args.count >= 3:
        guard let m = (try? JSONSerialization.jsonObject(with: Data(args[2].utf8))) as? [String: String] else {
            print("answers must be a JSON object of question text -> label"); return 2
        }
        req["op"] = "answer"; req["id"] = args[1]; req["answers"] = m
    case "tap" where args.count >= 2:
        req["op"] = "tap"; req["session"] = args[1]
    case "plan" where args.count >= 2, "open" where args.count >= 2:
        req["op"] = args[0]; req["session"] = args[1]
    case "demo":
        req["op"] = "demo"
        if args.count >= 2 { req["freeze"] = args[1] == "freeze" }
    case "notice":
        req["op"] = "notice"; req["which"] = args.count >= 2 ? args[1] : "none"
    case "screen":
        req["op"] = "screen"; req["which"] = args.count >= 2 ? args[1] : "real"
    case "record" where args.count >= 2:
        req["op"] = "record"; req["path"] = args[1]
        if args.count >= 3, let s = Double(args[2]) { req["seconds"] = s }
        if args.count >= 4, let f = Double(args[3]) { req["fps"] = f }
        if args.count >= 5, let k = Double(args[4]) { req["scale"] = k }
    case "layout":
        req["op"] = "layout"
    case "click", "doubleclick", "rightclick":
        guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { print(usage); return 2 }
        req["op"] = args[0]; req["x"] = x; req["y"] = y
    case "drag":
        guard args.count >= 5, let v = Optional(args[1...4].compactMap(Double.init)), v.count == 4 else { print(usage); return 2 }
        req["op"] = "drag"; req["x"] = v[0]; req["y"] = v[1]; req["x2"] = v[2]; req["y2"] = v[3]
    case "menu":
        req["op"] = "menu"
        if args.count >= 2, !args[1].isEmpty { req["session"] = args[1] }
        if args.count >= 3 { req["pick"] = args[2] }
    case "snapshot" where args.count >= 2:
        req["op"] = "snapshot"; req["path"] = args[1]
        if args.count >= 3 { req["window"] = args[2] }
        if args.count >= 4, let k = Double(args[3]) { req["scale"] = k }
    default:
        print(usage); return 2
    }
    guard let line = canonicalJSON(req).map({ Data(($0 + "\n").utf8) }),
          let reply = socketRequest(path: crewshelfSocketPath(), line: line, connectBy: Date().addingTimeInterval(1),
                                    writeBy: Date().addingTimeInterval(2),
                                    replyBy: Date().addingTimeInterval(req["op"] as? String == "open" ? 20 : 5)) else {
        print("Crewshelf is not running (no answer on \(crewshelfSocketPath()))"); return 1
    }
    let obj = try? JSONSerialization.jsonObject(with: reply)
    if let o = obj, let pretty = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: pretty, as: UTF8.self))
    }
    return ((obj as? [String: Any])?["ok"] as? Bool) == true ? 0 : 1
}

switch parseAppArgs(Array(CommandLine.arguments.dropFirst())) {
case .run: break
case .help: print(appUsage); exit(0)
case .bad(let a): FileHandle.standardError.write("Crewshelf: unknown option \(a)\n\n\(appUsage)\n".data(using: .utf8)!); exit(2)
}
if isDemo {
    // Before anything reads them: a demo never uses the real support folder (socket, app-path) or settings.
    for (k, v) in demoEnvironment(ProcessInfo.processInfo.environment) { setenv(k, v, 1) }
    if CommandLine.arguments.contains("--ctl") {     // `--demo --ctl ...`: talk to the running demo, change nothing
        exit(ctl(Array(CommandLine.arguments.drop(while: { $0 != "--ctl" }).dropFirst())))
    }
    // Every demo starts the same way (expanded, bottom-right, nothing muted): its own settings are reset.
    if ProcessInfo.processInfo.environment["CREWSHELF_DEFAULTS"] == demoDefaultsSuite {
        UserDefaults.standard.removePersistentDomain(forName: demoDefaultsSuite)
    }
}
if !isDemo, let code = MainActor.assumeIsolated({ cli() }) { exit(code) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
