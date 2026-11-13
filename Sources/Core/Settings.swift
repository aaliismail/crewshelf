import Foundation

// Settings from the right-click menu that need a rule: hide idle agents, and where launch at login may be used.

/// The characters a shelf shows when idle agents are hidden: everything that is working or waiting, plus any
/// idle one with something to show (an unread check mark, its open bubble). Departed (grey) ones count as idle.
public func shownOnShelf(_ sessions: [Session], hideIdle: Bool, keep: Set<String>) -> [Session] {
    guard hideIdle else { return sessions }
    return sessions.filter { s in
        let lk = look(for: s)
        return (lk == .working || lk == .blocked) || keep.contains(s.sessionId)
    }
}

/// Launch at login (SMAppService.mainApp) is offered only to a copy in /Applications or ~/Applications: macOS
/// starts the registered bundle, so a copy in a build folder or Downloads would break as soon as it moves.
public func launchAtLoginAllowed(bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
    let p = (bundlePath as NSString).standardizingPath
    guard p.hasSuffix(".app") else { return false }
    let homeApps = (home as NSString).appendingPathComponent("Applications") + "/"
    return p.hasPrefix("/Applications/") || p.hasPrefix(homeApps)
}

/// The commands the first-run bubble shows (and copies).
public let pluginRepo = "aaliismail/crewshelf"
public let pluginInstallCommands = ["/plugin marketplace add \(pluginRepo)", "/plugin install crewshelf@crewshelf"]
