import AppKit

/// The shelf's right-click menu: alerts (bubbles, sound, banners), Do Not Disturb, mute the agent under the pointer, settings (corner,
/// hide idle agents, launch at login), collapse, Quit.
final class ShelfMenus: NSObject {
    let model: CrewshelfModel
    private var actions: [Int: () -> Void] = [:]
    /// The corner the shelf is snapped into (nil when it was dragged somewhere else), and how to move it to one.
    var corner: () -> (HSide, VSide)? = { nil }
    var setCorner: (HSide, VSide) -> Void = { _, _ in }

    init(model: CrewshelfModel) { self.model = model }

    @objc private func fire(_ item: NSMenuItem) { actions[item.tag]?() }

    private func item(_ title: String, on: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        i.target = self
        i.tag = actions.count + 1
        i.state = on ? .on : .off
        i.isEnabled = enabled
        actions[i.tag] = action
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func build(agent: Session?) -> NSMenu {
        actions = [:]
        let m = NSMenu()
        m.autoenablesItems = false
        let now = Date()
        let calm = model.calm

        if let s = agent {
            let muted = calm.muted.contains(s.sessionId)
            m.addItem(header(s.name))
            m.addItem(item(muted ? "Unmute this agent" : "Mute this agent", on: muted) { [weak self] in self?.model.toggleMute(s.sessionId) })
            m.addItem(.separator())
        }

        let alerts = NSMenuItem(title: "Alerts", action: nil, keyEquivalent: "")
        let am = NSMenu()
        am.autoenablesItems = false
        // Each one on or off by itself (default: bubbles and sound).
        let a = calm.alerts
        am.addItem(item("Bubbles open on their own", on: a.bubbles) { [weak self] in
            var n = a; n.bubbles.toggle(); self?.model.setAlerts(n)
        })
        am.addItem(item("Sound", on: a.sound) { [weak self] in var n = a; n.sound.toggle(); self?.model.setAlerts(n) })
        am.addItem(item("Banners", on: a.banners) { [weak self] in var n = a; n.banners.toggle(); self?.model.setAlerts(n) })
        alerts.submenu = am
        m.addItem(alerts)

        let dnd = NSMenuItem(title: "Do Not Disturb", action: nil, keyEquivalent: "")
        let dm = NSMenu()
        dm.autoenablesItems = false
        if let until = calm.dndUntil, calm.dnd(now) {
            let f = DateFormatter()
            f.dateStyle = Calendar.current.isDate(until, inSameDayAs: now) ? .none : .short
            f.timeStyle = .short
            dm.addItem(header("On until \(f.string(from: until))"))
            dm.addItem(item("Turn off") { [weak self] in self?.model.setDND(nil) })
            dm.addItem(.separator())
        }
        dm.addItem(item("For 1 hour") { [weak self] in self?.model.setDND(Date().addingTimeInterval(3600)) })
        dm.addItem(item("Until tomorrow morning") { [weak self] in self?.model.setDND(nextMorning(after: Date())) })
        dnd.submenu = dm
        dnd.state = calm.dnd(now) ? .on : .off
        m.addItem(dnd)

        let mutedLive = model.shelf.filter { calm.muted.contains($0.sessionId) }
        if !mutedLive.isEmpty {
            m.addItem(item("Unmute all agents (\(mutedLive.count))") { [weak self] in self?.model.unmuteAll() })
        }
        m.addItem(.separator())
        let pos = NSMenuItem(title: "Corner", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        pm.autoenablesItems = false
        let here = corner()
        for (title, h, v) in [("Bottom right", HSide.right, VSide.bottom), ("Bottom left", .left, .bottom),
                              ("Top right", .right, .top), ("Top left", .left, .top)] {
            pm.addItem(item(title, on: here.map { $0 == (h, v) } ?? false) { [weak self] in self?.setCorner(h, v) })
        }
        pos.submenu = pm
        m.addItem(pos)
        m.addItem(item("Hide idle agents", on: model.hideIdle) { [weak self] in
            guard let self = self else { return }
            self.model.setHideIdle(!self.model.hideIdle)
        })
        if model.canShowInstallHint {
            m.addItem(item("Install the plugin…", on: model.notice == .install) { [weak self] in self?.model.showNotice(.install) })
        }
        if model.demo == nil {
            m.addItem(item("Launch at login", on: LoginItem.enabled) { [weak self] in
                guard let self = self else { return }
                LoginItem.toggle(self.model)
            })
        }
        m.addItem(.separator())
        m.addItem(item(model.collapsed ? "Expand shelf" : "Collapse shelf") { [weak self] in
            guard let self = self else { return }
            self.model.setCollapsed(!self.model.collapsed)
        })
        m.addItem(.separator())
        m.addItem(item("Quit Crewshelf") { NSApp.terminate(nil) })
        return m
    }
}
