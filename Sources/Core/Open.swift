import Foundation

// Open: find the terminal an agent runs in (Terminals.swift) and run the adapter's steps.

public let tmuxBin = firstExisting(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])

extension Engine {
    /// Everything the adapters need that is not in the hook env, looked up only for the terminal at hand.
    public func hostFacts(_ t: TerminalEnv) -> HostFacts {
        var f = HostFacts()
        let parents = t.pid.map { ancestry($0) } ?? []
        f.underTmux = parents.dropFirst().contains { $0.comm.hasPrefix("tmux") }
        f.owner = ownerApp(parents: parents, path: processPath, bundleId: bundleIdentifier)
        switch detectTerminal(t, ownerBundle: f.owner?.bundleId, underTmux: f.underTmux) {
        case .cmux where t.vars["CMUX_SURFACE_ID"] == nil || t.vars["CMUX_WORKSPACE_ID"] == nil:
            if let tty = t.tty { f.cmuxSurface = cmux?.surfaces().first { $0.tty == tty } }
        case .tmux:
            guard let tmux = tmuxBin else { break }
            let sock = TmuxAdapter.socketArgs(t.vars["TMUX"])
            var session: String?
            if let pane = t.vars["TMUX_PANE"] {
                f.tmuxPane = pane
                let r = run(tmux, sock + ["display-message", "-p", "-t", pane, "#{session_name}"], timeout: 3)
                if r.ok { session = r.out.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if let tty = t.tty {
                let r = run(tmux, sock + ["list-panes", "-a", "-F", tmuxPaneFormat], timeout: 3)
                if let hit = tmuxPane(forTty: tty, listing: r.out) { f.tmuxPane = hit.pane; session = hit.session }
            }
            let clients = parseTmuxClients(run(tmux, sock + ["list-clients", "-F", tmuxClientFormat], timeout: 3).out)
            f.tmuxClient = pickTmuxClient(clients, session: session)
            if let c = f.tmuxClient {
                f.tmuxHost = ownerApp(parents: ancestry(c.pid), path: processPath, bundleId: bundleIdentifier)
                if f.tmuxHost?.bundleId == TerminalBundle.cmux { f.tmuxHostSurface = cmux?.surfaces().first { $0.tty == c.tty } }
            }
        default:
            break
        }
        return f
    }

    /// Bring this agent's terminal tab to the front. Interactive sessions (and `claude -p` runs) by the terminal
    /// their hooks reported, or, for sessions without the plugin, by the app that owns their process. A background
    /// agent: the tab it is attached in, else (cmux) a new tab running `claude attach <id>`.
    public func jump(_ s: Session) -> ActionResult {
        if s.kind == .background && s.hostPid == nil { return jumpBackground(s) }
        var t = s.kind == .background ? TerminalEnv() : (s.terminal ?? TerminalEnv())
        if s.kind == .background { t.pid = s.hostPid } else if t.pid == nil { t.pid = s.pid }
        if t.tty == nil, let p = t.pid { t.tty = procEntry(p)?.tty }
        let plan = openPlan(t, hostFacts(t), cwd: s.cwd)
        guard !plan.steps.isEmpty else { return .fail(plan.note ?? "Couldn't find the terminal this agent runs in.") }
        return execute(plan)
    }

    /// Run every step (a failed one does not stop the rest, so the app still comes to the front). OK only when all
    /// of them worked; otherwise the first failure is the message.
    public func execute(_ plan: OpenPlan) -> ActionResult {
        var failures: [String] = []
        for step in plan.steps {
            let r = runStep(step)
            if !r.ok { failures.append(r.detail) }
        }
        if let first = failures.first { return .fail(first) }
        let name = plan.kind == .other ? "its app" : plan.kind.rawValue
        return ActionResult(ok: true, message: plan.note ?? "Opened in \(name).")
    }

    /// One step. AppleScript runs through osascript as a child of Crewshelf, so macOS asks once whether Crewshelf may
    /// control that terminal (Info.plist carries NSAppleEventsUsageDescription).
    public func runStep(_ step: OpenStep) -> (ok: Bool, detail: String) {
        if let fake = stepRunner { return fake(step) }
        switch step {
        case .run(let tool, let args):
            if tool == "cmux" {
                guard let c = cmux else { return (false, "cmux CLI not found.") }
                let r = c.call(args)
                return r.ok ? (true, "") : (false, c.denied ? cmuxBlockedNote : (c.lastError ?? "cmux \(args.first ?? "") failed."))
            }
            guard tool == "tmux", let bin = tmuxBin else { return (false, "\(tool) not found.") }
            let r = run(bin, args, timeout: 4)
            return r.ok ? (true, "") : (false, "tmux: " + (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines))
        case .appleScript(let source):
            let r = run("/usr/bin/osascript", ["-e", source], timeout: 8)
            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok && out == "ok" { return (true, "") }
            if r.ok && out == "several" {
                return (false, "More than one terminal is in this agent's folder; brought the terminal to the front.")
            }
            if r.ok { return (false, "Couldn't find its tab; brought the terminal to the front.") }
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.isEmpty && r.status == SIGTERM {
                // No answer in 8 s: macOS is showing its "Crewshelf wants to control ..." prompt (or the app hangs).
                return (false, "macOS is asking whether Crewshelf may control that terminal. Answer its prompt, then Open again.")
            }
            if err.contains("-1743") || err.contains("Not authorized") {
                return (false, "macOS blocked Crewshelf from controlling that terminal. Allow it in System Settings > Privacy & Security > Automation.")
            }
            return (false, err.isEmpty ? "AppleScript failed." : err)
        case .activate(let bundle):
            let r = run("/usr/bin/open", ["-b", bundle], timeout: 5)
            return r.ok ? (true, "") : (false, "Couldn't bring \(bundle) to the front.")
        case .activatePid(let pid):
            guard let exe = ancestry(pid).lazy.compactMap({ processPath($0.pid) }).first(where: { appBundlePath(executable: $0) != nil }),
                  let app = appBundlePath(executable: exe) else { return (false, "Couldn't find the app that runs this agent.") }
            let r = run("/usr/bin/open", ["-a", app], timeout: 5)
            return r.ok ? (true, "") : (false, "Couldn't bring \((app as NSString).lastPathComponent) to the front.")
        }
    }

    /// A background agent no tab has attached: in cmux, the tab running `claude attach <id>`, or a new one.
    func jumpBackground(_ s: Session) -> ActionResult {
        guard let cmux = cmux else { return .fail("No tab shows this agent. Run `claude attach \(s.cliId)` in a terminal.") }
        if let surf = surface(for: s) {
            return execute(OpenPlan(kind: .cmux, steps: Cmux.focusCommands(surf).map { .run(tool: "cmux", args: $0) }
                + [.activate(bundleId: TerminalBundle.cmux)], note: "Focused \(surf.surfaceRef)."))
        }
        if cmux.denied { return .fail(cmuxBlockedNote) }
        guard let id = s.shortId else { return .fail("This session is not in a terminal tab.") }
        guard let claude = claudeBin else { return .fail("claude CLI not found.") }
        let r = cmux.call(Cmux.attachCommand(claude: claude, id: id, cwd: s.cwd))
        guard r.ok else { return .fail(cmux.denied ? cmuxBlockedNote : (cmux.lastError ?? "cmux new-surface failed.")) }
        _ = runStep(.activate(bundleId: TerminalBundle.cmux))
        return ActionResult(ok: true, message: "Opened a tab: claude attach \(id).")
    }
}
