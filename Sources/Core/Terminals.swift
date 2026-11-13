import Foundation

// Open: bring an agent's own terminal tab to the front. Which terminal it runs in comes from the env its Claude
// Code process had (the plugin's hooks send an allowlist of terminal variables, its tty and its pid). Each terminal
// is one adapter behind `TerminalAdapter`; building the steps is pure (tested with fixtures), running them is the
// app's (AppleScript and app activation need AppKit). Open is a convenience: it never types into a terminal.

public enum TerminalKind: String, CaseIterable {
    case tmux, cmux, iterm = "iTerm2", terminal = "Terminal", ghostty = "Ghostty", other = "app"
}

public enum TerminalBundle {
    public static let cmux = "com.cmuxterm.app"
    public static let iterm = "com.googlecode.iterm2"
    public static let terminal = "com.apple.Terminal"
    public static let ghostty = "com.mitchellh.ghostty"
}

/// Which terminal a session runs in. The innermost terminal wins: each one sets TERM_PROGRAM for its own shells,
/// and LaunchServices sets __CFBundleIdentifier for the app's process tree, while variables of an outer terminal
/// leak into anything started from it (a Terminal window opened from a cmux tab still carries CMUX_*). So:
/// tmux when TERM_PROGRAM says so (tmux 3.2+) or TMUX is set with no TERM_PROGRAM; then TERM_PROGRAM; then the
/// bundle id; then terminal-specific ids. cmux sets TERM_PROGRAM=ghostty, so a "ghostty" session is cmux when
/// cmux owns it. Without variables (a session that predates the plugin), the app that owns the process decides,
/// or `underTmux` when a tmux server is one of its parents.
public func detectTerminal(_ t: TerminalEnv, ownerBundle: String? = nil, underTmux: Bool = false) -> TerminalKind {
    let v = t.vars
    func has(_ k: String) -> Bool { !(v[k] ?? "").isEmpty }
    let program = v["TERM_PROGRAM"] ?? ""
    let bundle = v["__CFBundleIdentifier"] ?? ""
    let cmuxIds = has("CMUX_SURFACE_ID") || has("CMUX_WORKSPACE_ID")
    if program == "tmux" || (has("TMUX") && program.isEmpty) { return .tmux }
    switch program {
    case "Apple_Terminal": return .terminal
    case "iTerm.app": return .iterm
    case "ghostty":
        if bundle == TerminalBundle.cmux || (cmuxIds && bundle != TerminalBundle.ghostty) { return .cmux }
        return .ghostty
    case "": break
    default: return .other          // vscode, WezTerm, Hyper, ...: the app that owns it comes to the front
    }
    switch bundle {
    case TerminalBundle.cmux: return .cmux
    case TerminalBundle.iterm: return .iterm
    case TerminalBundle.terminal: return .terminal
    case TerminalBundle.ghostty: return .ghostty
    default: break
    }
    if has("ITERM_SESSION_ID") { return .iterm }
    if cmuxIds { return .cmux }
    if underTmux { return .tmux }
    switch ownerBundle {
    case TerminalBundle.cmux?: return .cmux
    case TerminalBundle.iterm?: return .iterm
    case TerminalBundle.terminal?: return .terminal
    case TerminalBundle.ghostty?: return .ghostty
    default: return .other
    }
}

/// One thing the app does to open a tab.
public enum OpenStep: Equatable {
    case run(tool: String, args: [String])      // a CLI: "cmux" or "tmux" (the app resolves the binary)
    case appleScript(String)                    // run in-process; returns "ok" when it found the tab
    case activate(bundleId: String)             // bring a running app to the front
    case activatePid(Int)                       // bring the app that owns this process to the front
}

public struct TmuxClient: Equatable {
    public var pid: Int
    public var tty: String
    public var session: String
    public var activity: Double
    public init(pid: Int, tty: String, session: String, activity: Double) {
        self.pid = pid; self.tty = tty; self.session = session; self.activity = activity
    }
}

/// The app that shows a tmux client: the terminal it runs in, by its env-free facts.
public struct HostApp: Equatable {
    public var bundleId: String?
    public var pid: Int?
    public init(bundleId: String?, pid: Int?) { self.bundleId = bundleId; self.pid = pid }
}

/// What the app found out before planning (each part is only looked up for the terminal that needs it).
public struct HostFacts: Equatable {
    public var owner: HostApp?             // the app the claude process runs under (walking its parents)
    public var underTmux = false           // a tmux server is one of its parents
    public var cmuxSurface: SurfaceRef?    // the cmux tab with this tty (no cmux ids in the env)
    public var tmuxPane: String?           // "%3": from TMUX_PANE, or found by tty
    public var tmuxClient: TmuxClient?     // the client showing that pane's session, most recently used
    public var tmuxHost: HostApp?          // the app that runs that client
    public var tmuxHostSurface: SurfaceRef?   // the client's cmux tab, when its host is cmux
    public init() {}
}

public struct OpenPlan: Equatable {
    public var kind: TerminalKind
    public var steps: [OpenStep]
    public var note: String?               // why the plan is weaker than a direct jump
}

public protocol TerminalAdapter {
    var kind: TerminalKind { get }
    func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan
}

/// AppleScript string literal.
public func asString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

public struct CmuxAdapter: TerminalAdapter {
    public let kind = TerminalKind.cmux
    public init() {}
    public func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan {
        if let ws = t.vars["CMUX_WORKSPACE_ID"], let surf = t.vars["CMUX_SURFACE_ID"] {
            return OpenPlan(kind: kind, steps: [
                .run(tool: "cmux", args: ["select-workspace", "--workspace", ws]),
                .run(tool: "cmux", args: ["focus-panel", "--panel", surf, "--workspace", ws]),
                .activate(bundleId: TerminalBundle.cmux),
            ], note: nil)
        }
        if let s = f.cmuxSurface {
            return OpenPlan(kind: kind, steps: Cmux.focusCommands(s).map { .run(tool: "cmux", args: $0) }
                + [.activate(bundleId: TerminalBundle.cmux)], note: nil)
        }
        return OpenPlan(kind: kind, steps: [.activate(bundleId: TerminalBundle.cmux)], note: "Couldn't find its cmux tab.")
    }
}

/// iTerm2: the session whose unique id is the part of ITERM_SESSION_ID after the colon ("w0t1p0:<uuid>"), or
/// else whose tty matches. Selects its window, tab and session, then activates iTerm2.
public struct ITermAdapter: TerminalAdapter {
    public let kind = TerminalKind.iterm
    public init() {}
    public static func sessionId(_ v: String?) -> String? {
        guard let v = v, !v.isEmpty else { return nil }
        let id = v.split(separator: ":", maxSplits: 1).last.map(String.init) ?? v
        return id.isEmpty ? nil : id
    }
    public func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan {
        let id = ITermAdapter.sessionId(t.vars["ITERM_SESSION_ID"])
        guard id != nil || t.tty != nil else {
            return OpenPlan(kind: kind, steps: [.activate(bundleId: TerminalBundle.iterm)], note: "No iTerm2 session id or tty.")
        }
        return OpenPlan(kind: kind, steps: [.appleScript(ITermAdapter.script(sessionId: id, tty: t.tty))], note: nil)
    }
    public static func script(sessionId: String?, tty: String?) -> String {
        var test: [String] = []
        if let id = sessionId { test.append("(unique id of s) is \(asString(id))") }
        if let t = tty { test.append("(tty of s) is \(asString("/dev/" + t))") }
        return """
        tell application id "\(TerminalBundle.iterm)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if \(test.joined(separator: " or ")) then
                  tell w to select
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          activate
          return "not found"
        end tell
        """
    }
}

/// Terminal.app: the tab whose tty is the session's, selected and brought to the front.
public struct AppleTerminalAdapter: TerminalAdapter {
    public let kind = TerminalKind.terminal
    public init() {}
    public func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan {
        guard let tty = t.tty else {
            return OpenPlan(kind: kind, steps: [.activate(bundleId: TerminalBundle.terminal)], note: "No tty for this session.")
        }
        return OpenPlan(kind: kind, steps: [.appleScript(AppleTerminalAdapter.script(tty: tty))], note: nil)
    }
    public static func script(tty: String) -> String {
        """
        tell application id "\(TerminalBundle.terminal)"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is \(asString("/dev/" + tty)) then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
          activate
          return "not found"
        end tell
        """
    }
}

/// Ghostty: 1.3 and later are scriptable, but a terminal there has no tty, and Ghostty puts no id of its own in the
/// env (GHOSTTY_SURFACE_ID is cmux's, not Ghostty's). So the session's terminal is the one whose working directory
/// is the session's: focused when it is the only one; with several there ("several") or none, Ghostty is just
/// activated. Older Ghostty: the script fails and Ghostty is activated.
public struct GhosttyAdapter: TerminalAdapter {
    public let kind = TerminalKind.ghostty
    public init() {}
    public func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan {
        plan(t, f, cwd: nil)
    }
    public func plan(_ t: TerminalEnv, _ f: HostFacts, cwd: String?) -> OpenPlan {
        guard let c = cwd, !c.isEmpty else {
            return OpenPlan(kind: kind, steps: [.activate(bundleId: TerminalBundle.ghostty)],
                            note: "Brought Ghostty to the front; the tab is up to you.")
        }
        return OpenPlan(kind: kind, steps: [.appleScript(GhosttyAdapter.script(cwd: c)),
                                            .activate(bundleId: TerminalBundle.ghostty)], note: nil)
    }
    public static func script(cwd: String) -> String {
        let bare = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return """
        tell application id "\(TerminalBundle.ghostty)"
          set hits to (terminals whose working directory is \(asString(bare)) or working directory is \(asString(bare + "/")))
          if (count of hits) is 1 then
            focus (item 1 of hits)
            return "ok"
          end if
          activate
          if (count of hits) > 1 then return "several"
          return "not found"
        end tell
        """
    }
}

/// tmux: select the pane's window and the pane, switch the most recently used client to that session, then
/// bring that client's terminal to the front (its own tab where the host terminal can be told which one).
public struct TmuxAdapter: TerminalAdapter {
    public let kind = TerminalKind.tmux
    public init() {}

    /// `-S <socket>` from TMUX ("<socket>,<server pid>,<session index>"); none means the default server.
    public static func socketArgs(_ tmuxVar: String?) -> [String] {
        guard let v = tmuxVar, let path = v.split(separator: ",").first, path.hasPrefix("/") else { return [] }
        return ["-S", String(path)]
    }

    public func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan {
        let sock = TmuxAdapter.socketArgs(t.vars["TMUX"])
        guard let pane = t.vars["TMUX_PANE"] ?? f.tmuxPane else {
            return OpenPlan(kind: kind, steps: f.tmuxHost.map(hostSteps) ?? [], note: "Couldn't find its tmux pane.")
        }
        var steps: [OpenStep] = [.run(tool: "tmux", args: sock + ["select-window", "-t", pane]),
                                 .run(tool: "tmux", args: sock + ["select-pane", "-t", pane])]
        guard let c = f.tmuxClient else {
            return OpenPlan(kind: kind, steps: steps, note: "No terminal is attached to its tmux session.")
        }
        steps.append(.run(tool: "tmux", args: sock + ["switch-client", "-c", "/dev/" + c.tty, "-t", pane]))
        var host = f.tmuxHost ?? HostApp(bundleId: nil, pid: c.pid)
        if host.pid == nil { host.pid = c.pid }
        steps += hostSteps(host, clientTty: c.tty, surface: f.tmuxHostSurface)
        return OpenPlan(kind: kind, steps: steps, note: nil)
    }

    private func hostSteps(_ h: HostApp) -> [OpenStep] { hostSteps(h, clientTty: nil, surface: nil) }

    /// The terminal a tmux client runs in: its own tab when that terminal can select one by tty.
    func hostSteps(_ h: HostApp, clientTty: String?, surface: SurfaceRef?) -> [OpenStep] {
        switch h.bundleId {
        case TerminalBundle.terminal? where clientTty != nil:
            return [.appleScript(AppleTerminalAdapter.script(tty: clientTty!))]
        case TerminalBundle.iterm? where clientTty != nil:
            return [.appleScript(ITermAdapter.script(sessionId: nil, tty: clientTty))]
        case TerminalBundle.cmux? where surface != nil:
            return Cmux.focusCommands(surface!).map { .run(tool: "cmux", args: $0) } + [.activate(bundleId: TerminalBundle.cmux)]
        case let b?:
            return [.activate(bundleId: b)]
        case nil:
            return h.pid.map { [.activatePid($0)] } ?? []
        }
    }
}

/// Any other terminal (VS Code, WezTerm, kitty, Warp, Alacritty, ...): bring the app that owns the claude process
/// to the front, found by walking its parents. The tab inside it is left as it is.
public struct FallbackAdapter: TerminalAdapter {
    public let kind = TerminalKind.other
    public init() {}
    public func plan(_ t: TerminalEnv, _ f: HostFacts) -> OpenPlan {
        if let b = f.owner?.bundleId {
            return OpenPlan(kind: kind, steps: [.activate(bundleId: b)], note: "Brought its app to the front; the tab is up to you.")
        }
        if let p = f.owner?.pid ?? t.pid {
            return OpenPlan(kind: kind, steps: [.activatePid(p)], note: "Brought its app to the front; the tab is up to you.")
        }
        return OpenPlan(kind: kind, steps: [], note: "Couldn't find the terminal this agent runs in.")
    }
}

public let terminalAdapters: [TerminalAdapter] = [TmuxAdapter(), CmuxAdapter(), ITermAdapter(), AppleTerminalAdapter(),
                                                  GhosttyAdapter(), FallbackAdapter()]

/// The steps that open a session's tab. `cwd` is how Ghostty's terminal is found (it has no tty or id to match).
public func openPlan(_ t: TerminalEnv, _ f: HostFacts, cwd: String? = nil) -> OpenPlan {
    let kind = detectTerminal(t, ownerBundle: f.owner?.bundleId, underTmux: f.underTmux)
    if kind == .ghostty { return GhosttyAdapter().plan(t, f, cwd: cwd) }
    let a = terminalAdapters.first { $0.kind == kind } ?? FallbackAdapter()
    return a.plan(t, f)
}

// MARK: parsing what the CLIs print

/// The format string for `tmux list-clients -F`.
public let tmuxClientFormat = "#{client_pid}\t#{client_tty}\t#{session_name}\t#{client_activity}"

public func parseTmuxClients(_ text: String) -> [TmuxClient] {
    text.split(separator: "\n").compactMap { line in
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 4, let pid = Int(p[0]), let tty = cleanTty(p[1]) else { return nil }
        return TmuxClient(pid: pid, tty: tty, session: p[2], activity: Double(p[3]) ?? 0)
    }
}

/// The client to bring forward: the most recently active one showing `session`, else the most recently active
/// client of that server (it is switched to the session). None when no terminal is attached at all.
public func pickTmuxClient(_ clients: [TmuxClient], session: String?) -> TmuxClient? {
    let mine = clients.filter { $0.session == session }
    return (mine.isEmpty ? clients : mine).max { $0.activity < $1.activity }
}

/// The format string for `tmux list-panes -a -F`.
public let tmuxPaneFormat = "#{pane_id}\t#{pane_tty}\t#{session_name}"

/// From `tmux list-panes -a -F tmuxPaneFormat`: the pane (and its session) whose tty is `tty`.
public func tmuxPane(forTty tty: String, listing: String) -> (pane: String, session: String)? {
    for line in listing.split(separator: "\n") {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 3, cleanTty(p[1]) == tty else { continue }
        return (p[0], p[2])
    }
    return nil
}

/// The app that owns a process: the nearest of its parents (given nearest first) whose executable lies in an
/// `.app` bundle (the outermost bundle of that path, so an app's helper counts as the app).
public func ownerApp(parents: [ProcEntry], path: (Int) -> String?, bundleId: (String) -> String?) -> HostApp? {
    for e in parents {
        guard let exe = path(e.pid), let app = appBundlePath(executable: exe) else { continue }
        return HostApp(bundleId: bundleId(app), pid: e.pid)
    }
    return nil
}

public func bundleIdentifier(appPath: String) -> String? {
    guard let d = FileManager.default.contents(atPath: appPath + "/Contents/Info.plist"),
          let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return nil }
    return p["CFBundleIdentifier"] as? String
}
