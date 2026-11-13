import Foundation

// P3: terminal adapters (detection and command construction from fixtures, one live tmux run), the first-run
// notice, settings, demo mode, displays.

func envFixture(_ pairs: [String: String], tty: String? = nil, pid: Int? = nil) -> TerminalEnv {
    TerminalEnv(vars: captureTerminalVars(pairs), tty: tty, pid: pid)
}

let cmuxEnv = envFixture(["TERM_PROGRAM": "ghostty", "GHOSTTY_RESOURCES_DIR": "/Applications/cmux.app/Contents/Resources/ghostty",
                          "CMUX_WORKSPACE_ID": "1D2C3B4A-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "CMUX_SURFACE_ID": "3F4C2AB9-43EA-4640-A4C6-208B5BED5202",
                          "CMUX_SOCKET_PASSWORD": "hunter2", "CMUX_SOCKET_CAPABILITY": "v1.secret", "CMUX_CUA_SOCKET_AUTH_TOKEN": "tok",
                          "__CFBundleIdentifier": "com.cmuxterm.app"], tty: "ttys001", pid: 9030)
let itermEnv = envFixture(["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:6B2E8F1A-1D3C-4E5F-8A9B-0C1D2E3F4A5B",
                           "LC_TERMINAL": "iTerm2", "__CFBundleIdentifier": "com.googlecode.iterm2"], tty: "ttys005", pid: 501)
let appleEnv = envFixture(["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "8C0F1B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B",
                           "__CFBundleIdentifier": "com.apple.Terminal"], tty: "ttys003", pid: 502)
// What Ghostty 1.3 really sets: no surface or window id of its own (GHOSTTY_SURFACE_ID is cmux's).
let ghosttyEnv = envFixture(["TERM_PROGRAM": "ghostty", "TERM_PROGRAM_VERSION": "1.3.1",
                             "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty",
                             "__CFBundleIdentifier": "com.mitchellh.ghostty"], tty: "ttys006", pid: 503)
let tmuxEnv = envFixture(["TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,56245,0", "TMUX_PANE": "%3",
                          "LC_TERMINAL": "iTerm2"], tty: "ttys008", pid: 504)

func terminalTests() {
    // Detection
    eq(detectTerminal(cmuxEnv), .cmux, "cmux (TERM_PROGRAM=ghostty) is cmux, not Ghostty")
    eq(detectTerminal(itermEnv), .iterm, "iTerm2")
    eq(detectTerminal(appleEnv), .terminal, "Terminal.app")
    eq(detectTerminal(ghosttyEnv), .ghostty, "Ghostty")
    eq(detectTerminal(tmuxEnv), .tmux, "tmux inside iTerm2 is tmux")
    var tmuxInCmux = cmuxEnv
    tmuxInCmux.vars["TMUX"] = "/private/tmp/tmux-501/default,1,0"
    eq(detectTerminal(tmuxInCmux), .cmux, "tmux older than 3.2 in cmux (TERM_PROGRAM left as ghostty): the cmux tab running it")
    tmuxInCmux.vars["TERM_PROGRAM"] = "tmux"
    eq(detectTerminal(tmuxInCmux), .tmux, "tmux inside cmux is tmux")
    eq(detectTerminal(envFixture(["TERM_PROGRAM": "vscode"])), .other, "VS Code: the fallback")
    eq(detectTerminal(envFixture(["TERM_PROGRAM": "WezTerm"])), .other, "WezTerm: the fallback")
    eq(detectTerminal(TerminalEnv(), ownerBundle: TerminalBundle.iterm), .iterm, "no env, owned by iTerm2")
    eq(detectTerminal(TerminalEnv(), ownerBundle: TerminalBundle.cmux), .cmux, "no env, owned by cmux")
    eq(detectTerminal(TerminalEnv(), ownerBundle: "com.microsoft.VSCode"), .other, "no env, owned by another app")
    eq(detectTerminal(TerminalEnv(), ownerBundle: nil, underTmux: true), .tmux, "no env, under a tmux server")
    eq(detectTerminal(envFixture(["__CFBundleIdentifier": "com.apple.Terminal"])), .terminal, "bundle id alone")
    // Variables leak from an outer terminal into apps started from it (seen live: a Terminal window opened from cmux).
    let leaked = envFixture(["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "AFBFFCDC", "__CFBundleIdentifier": "com.apple.Terminal",
                             "CMUX_SURFACE_ID": "3F4C2AB9", "CMUX_WORKSPACE_ID": "1D2C3B4A", "GHOSTTY_SURFACE_ID": "0x5f9d"], tty: "ttys005")
    eq(detectTerminal(leaked), .terminal, "Terminal opened from cmux: Terminal, not cmux")
    eq(detectTerminal(envFixture(["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:X", "CMUX_SURFACE_ID": "S", "__CFBundleIdentifier": "com.googlecode.iterm2"])),
       .iterm, "iTerm2 opened from cmux: iTerm2")
    eq(detectTerminal(envFixture(["TERM_PROGRAM": "ghostty", "CMUX_SURFACE_ID": "S", "__CFBundleIdentifier": "com.mitchellh.ghostty"])),
       .ghostty, "Ghostty opened from cmux: Ghostty")
    eq(detectTerminal(envFixture(["TERM_PROGRAM": "ghostty", "CMUX_SURFACE_ID": "S", "CMUX_WORKSPACE_ID": "W"])), .cmux, "ghostty plus cmux ids, no bundle id: cmux")
    eq(detectTerminal(envFixture(["TERM_PROGRAM": "Apple_Terminal", "TMUX": "/tmp/x,1,0", "TMUX_PANE": "%1"])), .terminal,
       "a stale TMUX in a Terminal window started from tmux: Terminal")
    eq(detectTerminal(envFixture(["TMUX": "/tmp/x,1,0", "TMUX_PANE": "%1"])), .tmux, "old tmux (no TERM_PROGRAM): tmux")
    eq(detectTerminal(envFixture(["ITERM_SESSION_ID": "w0t0p0:X"])), .iterm, "only an iTerm session id")

    // Only the allowlist leaves the hook: no socket passwords, no PATH, nothing multi-line or huge.
    check(cmuxEnv.vars["CMUX_SOCKET_PASSWORD"] == nil && cmuxEnv.vars["CMUX_SOCKET_CAPABILITY"] == nil
          && cmuxEnv.vars["CMUX_CUA_SOCKET_AUTH_TOKEN"] == nil, "cmux secrets are never captured")
    check(cmuxEnv.vars["GHOSTTY_RESOURCES_DIR"] == nil, "unlisted variables are dropped")
    eq(Set(captureTerminalVars(["PATH": "/bin", "HOME": "/Users/x", "TERM_PROGRAM": "iTerm.app"]).keys), ["TERM_PROGRAM"], "allowlist only")
    eq(captureTerminalVars(["TERM_SESSION_ID": "a\nb", "TMUX_PANE": String(repeating: "x", count: 400)]), [:], "no newlines, no huge values")
    let wire = TerminalEnv(wire: ["vars": ["TERM_PROGRAM": "iTerm.app", "AWS_SECRET_ACCESS_KEY": "x", "TMUX_PANE": 3], "tty": "/dev/ttys005", "pid": 77])
    eq(wire, TerminalEnv(vars: ["TERM_PROGRAM": "iTerm.app"], tty: "ttys005", pid: 77), "wire: allowlist again, /dev/ stripped")
    eq(TerminalEnv(wire: ["vars": [:], "tty": "../../etc/passwd"]), nil, "a bad tty is dropped (and an empty env is none)")
    eq(TerminalEnv(wire: itermEnv.wire), itermEnv, "wire round trip")
    eq(TerminalEnv(wire: "nope"), nil, "garbage term")

    // The claude process among the hook's parents.
    let parents = [ProcEntry(pid: 900, ppid: 800, comm: "sh", tty: "ttys004"), ProcEntry(pid: 800, ppid: 700, comm: "claude", tty: "ttys004"),
                   ProcEntry(pid: 700, ppid: 600, comm: "zsh", tty: "ttys004"), ProcEntry(pid: 600, ppid: 1, comm: "cmux", tty: nil)]
    let cap = captureTerminal(env: ["TERM_PROGRAM": "ghostty", "CMUX_SURFACE_ID": "S", "SECRET": "x"], parents: parents)
    eq(cap, TerminalEnv(vars: ["TERM_PROGRAM": "ghostty", "CMUX_SURFACE_ID": "S"], tty: "ttys004", pid: 800), "capture: claude pid and its tty")
    eq(claudeProcess(in: [ProcEntry(pid: 9, ppid: 8, comm: "bash", tty: nil), ProcEntry(pid: 8, ppid: 1, comm: "node", tty: "ttys002")])?.pid, 8,
       "claude run by node: the first non-shell parent")
    let table = [5: ProcEntry(pid: 5, ppid: 4, comm: "a", tty: nil), 4: ProcEntry(pid: 4, ppid: 5, comm: "b", tty: nil)]
    eq(ancestry(5, lookup: { table[$0] }).map { $0.pid }, [5, 4], "ancestry stops at a loop")
    let me = procEntry(Int(getpid()))
    eq(me?.comm ?? "", "crewshelf-tests", "procEntry reads this process's name with sysctl")
    eq(ancestry(Int(getpid())).first?.pid ?? 0, Int(getpid()), "ancestry starts at the process itself")

    // The app that owns a process.
    eq(appBundlePath(executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2"), "/Applications/iTerm.app", "app of an executable")
    eq(appBundlePath(executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
       "/Applications/Visual Studio Code.app", "a helper counts as its outer app")
    eq(appBundlePath(executable: "/opt/homebrew/bin/claude"), nil, "a CLI is no app")
    let paths = [800: "/opt/homebrew/bin/claude", 700: "/bin/zsh", 600: "/Applications/cmux.app/Contents/MacOS/cmux"]
    eq(ownerApp(parents: parents, path: { paths[$0] }, bundleId: { $0 == "/Applications/cmux.app" ? TerminalBundle.cmux : nil }),
       HostApp(bundleId: TerminalBundle.cmux, pid: 600), "owner: the nearest parent in an app")
    eq(bundleIdentifier(appPath: "/System/Applications/Utilities/Terminal.app"), TerminalBundle.terminal, "bundle id from Info.plist")

    // Plans: cmux
    var f = HostFacts()
    eq(openPlan(cmuxEnv, f).steps, [
        .run(tool: "cmux", args: ["select-workspace", "--workspace", "1D2C3B4A-5E6F-4A7B-8C9D-0E1F2A3B4C5D"]),
        .run(tool: "cmux", args: ["focus-panel", "--panel", "3F4C2AB9-43EA-4640-A4C6-208B5BED5202", "--workspace", "1D2C3B4A-5E6F-4A7B-8C9D-0E1F2A3B4C5D"]),
        .activate(bundleId: TerminalBundle.cmux)], "cmux by its workspace and surface ids")
    let surf = SurfaceRef(windowRef: "window:1", workspaceRef: "workspace:2", paneRef: "pane:3", surfaceRef: "surface:4", title: "", tty: "ttys001")
    f.cmuxSurface = surf
    f.owner = HostApp(bundleId: TerminalBundle.cmux, pid: 600)
    eq(openPlan(TerminalEnv(tty: "ttys001", pid: 9030), f).steps,
       Cmux.focusCommands(surf).map { .run(tool: "cmux", args: $0) } + [.activate(bundleId: TerminalBundle.cmux)],
       "cmux without ids (no plugin): the tab with its tty")
    f = HostFacts()
    f.owner = HostApp(bundleId: TerminalBundle.cmux, pid: 600)
    let lost = openPlan(TerminalEnv(pid: 9030), f)
    eq(lost.steps, [.activate(bundleId: TerminalBundle.cmux)], "cmux, tab not found: activate cmux")
    check(lost.note != nil, "and says so")

    // iTerm2
    eq(ITermAdapter.sessionId("w0t1p0:6B2E8F1A-1D3C"), "6B2E8F1A-1D3C", "iTerm session id after the colon")
    eq(ITermAdapter.sessionId("6B2E8F1A"), "6B2E8F1A", "iTerm session id without a prefix")
    guard case .appleScript(let its)? = openPlan(itermEnv, HostFacts()).steps.first else { return check(false, "iTerm plan is a script") }
    check(its.contains("(unique id of s) is \"6B2E8F1A-1D3C-4E5F-8A9B-0C1D2E3F4A5B\""), "iTerm: matches the session id")
    check(its.contains("(tty of s) is \"/dev/ttys005\""), "iTerm: or its tty")
    check(its.contains("tell s to select") && its.contains("tell t to select") && its.contains("tell w to select") && its.contains("activate"),
          "iTerm: selects window, tab and session, then activates")
    check(its.contains("application id \"com.googlecode.iterm2\""), "iTerm: by bundle id")

    // Terminal.app
    guard case .appleScript(let ts)? = openPlan(appleEnv, HostFacts()).steps.first else { return check(false, "Terminal plan is a script") }
    check(ts.contains("tty of t is \"/dev/ttys003\"") && ts.contains("set selected of t to true") && ts.contains("set index of w to 1"),
          "Terminal: the tab by tty, selected, its window to the front")
    eq(openPlan(envFixture(["TERM_PROGRAM": "Apple_Terminal"]), HostFacts()).steps, [.activate(bundleId: TerminalBundle.terminal)],
       "Terminal without a tty: just activate")

    // Ghostty: found by the session's folder only, since Ghostty has no tty or id of its own to match on.
    let gp = openPlan(ghosttyEnv, HostFacts(), cwd: "/Users/demo/code/api")
    guard case .appleScript(let gs)? = gp.steps.first else { return check(false, "Ghostty plan is a script") }
    check(gs.contains("terminals whose working directory is \"/Users/demo/code/api\" or working directory is \"/Users/demo/code/api/\""),
          "Ghostty: the terminal in the session's directory")
    check(gs.contains("if (count of hits) is 1 then") && gs.contains("focus (item 1 of hits)"), "Ghostty: focused only when it is the only one")
    check(gs.contains("return \"several\""), "Ghostty: several in that folder is reported, not guessed")
    check(!gs.contains("id of"), "Ghostty: no id match (Ghostty sets no GHOSTTY_SURFACE_ID)")
    var withCmuxVar = ghosttyEnv
    withCmuxVar.vars["GHOSTTY_SURFACE_ID"] = "0x5f9de464b6f3a3d9"
    check(captureTerminalVars(["GHOSTTY_SURFACE_ID": "0x5f9d"]).isEmpty, "GHOSTTY_SURFACE_ID is not captured (only cmux sets it)")
    eq(openPlan(withCmuxVar, HostFacts(), cwd: "/Users/demo/code/api"), gp, "Ghostty: the plan never depends on GHOSTTY_SURFACE_ID")
    eq(gp.steps.last, .activate(bundleId: TerminalBundle.ghostty), "Ghostty: activated in any case")
    eq(openPlan(envFixture(["TERM_PROGRAM": "ghostty"]), HostFacts()).steps, [.activate(bundleId: TerminalBundle.ghostty)],
       "Ghostty with nothing to match: activate")
    check(GhosttyAdapter.script(cwd: "/Users/demo/code/api/").contains("is \"/Users/demo/code/api\" or"), "Ghostty: a trailing slash is ignored")

    // tmux
    let sock = ["-S", "/private/tmp/tmux-501/default"]
    eq(TmuxAdapter.socketArgs("/private/tmp/tmux-501/default,56245,0"), sock, "tmux socket from TMUX")
    eq(TmuxAdapter.socketArgs(nil), [], "no TMUX: default server")
    var tf = HostFacts()
    tf.tmuxClient = TmuxClient(pid: 77, tty: "ttys009", session: "work", activity: 5)
    tf.tmuxHost = HostApp(bundleId: TerminalBundle.terminal, pid: 70)
    let tp = openPlan(tmuxEnv, tf)
    eq(Array(tp.steps.prefix(3)), [.run(tool: "tmux", args: sock + ["select-window", "-t", "%3"]),
                                   .run(tool: "tmux", args: sock + ["select-pane", "-t", "%3"]),
                                   .run(tool: "tmux", args: sock + ["switch-client", "-c", "/dev/ttys009", "-t", "%3"])],
       "tmux: window, pane, then the client switches to it")
    eq(tp.steps.last, .appleScript(AppleTerminalAdapter.script(tty: "ttys009")), "tmux in Terminal.app: then the client's Terminal tab")
    tf.tmuxHost = HostApp(bundleId: TerminalBundle.cmux, pid: 600)
    tf.tmuxHostSurface = surf
    eq(Array(openPlan(tmuxEnv, tf).steps.dropFirst(3)), Cmux.focusCommands(surf).map { .run(tool: "cmux", args: $0) } + [.activate(bundleId: TerminalBundle.cmux)],
       "tmux in cmux: the client's cmux tab")
    tf.tmuxHost = nil
    tf.tmuxHostSurface = nil
    eq(openPlan(tmuxEnv, tf).steps.last, .activatePid(77), "tmux in an unknown terminal: the app that runs the client")
    tf.tmuxClient = nil
    let detached = openPlan(tmuxEnv, tf)
    eq(detached.steps.count, 2, "no client attached: only the window and pane")
    check(detached.note?.contains("attached") == true, "and says no terminal is attached")
    var paneless = HostFacts()
    paneless.underTmux = true
    paneless.tmuxPane = "%7"
    eq(openPlan(TerminalEnv(tty: "ttys011", pid: 9), paneless).steps.first, .run(tool: "tmux", args: ["select-window", "-t", "%7"]),
       "a session without the plugin under tmux: its pane found by tty")
    eq(parseTmuxClients("77\t/dev/ttys009\twork\t1700000000\n88\t/dev/ttys010\tother\t1700000500\nbad line\n"),
       [TmuxClient(pid: 77, tty: "ttys009", session: "work", activity: 1_700_000_000),
        TmuxClient(pid: 88, tty: "ttys010", session: "other", activity: 1_700_000_500)], "list-clients parsed")
    let clients = parseTmuxClients("1\t/dev/ttys001\twork\t10\n2\t/dev/ttys002\twork\t30\n3\t/dev/ttys003\tother\t99\n")
    eq(pickTmuxClient(clients, session: "work")?.pid, 2, "the most recently used client of the pane's session")
    eq(pickTmuxClient(clients, session: "none")?.pid, 3, "no client on that session: the server's most recent client")
    eq(pickTmuxClient([], session: "work"), nil, "no client at all")
    check(tmuxPane(forTty: "ttys002", listing: "%1\t/dev/ttys001\tmain\n%4\t/dev/ttys002\twork\n").map { $0.pane == "%4" && $0.session == "work" } == true,
          "list-panes: the pane with that tty")

    // Fallback
    var of = HostFacts()
    of.owner = HostApp(bundleId: "com.microsoft.VSCode", pid: 12)
    eq(openPlan(envFixture(["TERM_PROGRAM": "vscode"], pid: 13), of).steps, [.activate(bundleId: "com.microsoft.VSCode")], "fallback: the owning app")
    of.owner = HostApp(bundleId: nil, pid: 12)
    eq(openPlan(envFixture(["TERM_PROGRAM": "vscode"], pid: 13), of).steps, [.activatePid(12)], "fallback: by pid when it has no bundle id")
    let none = openPlan(TerminalEnv(), HostFacts())
    check(none.steps.isEmpty && none.note != nil, "fallback with nothing known: no steps, a reason")
    eq(asString("say \"hi\" \\ bye"), "\"say \\\"hi\\\" \\\\ bye\"", "AppleScript strings are escaped")
    check(!AppleTerminalAdapter.script(tty: "ttys0\" & (do shell script \"x\") & \"").contains("& (do shell script \"x\")"),
          "a hostile tty can't break out of the AppleScript string")

    // Engine.jump runs the plan's steps (recorded here, not run).
    let engine = Engine(claudeDir: tmpBase + "no-claude")
    var ran: [OpenStep] = []
    engine.stepRunner = { ran.append($0); return (true, "") }
    var tab = Session(sessionId: "s1", name: "api", cwd: "/tmp", kind: .interactive, state: .blocked)
    tab.terminal = cmuxEnv
    let r1 = engine.jump(tab)
    check(r1.ok, "jump ok: \(r1.message)")
    eq(ran, openPlan(cmuxEnv, HostFacts()).steps, "jump runs the cmux plan")
    ran = []
    engine.stepRunner = { step in ran.append(step); if case .run = step { return (false, "Access denied") }; return (true, "") }
    let r2 = engine.jump(tab)
    check(!r2.ok && r2.message == "Access denied", "a failed step fails Open with its reason")
    eq(ran.last, .activate(bundleId: TerminalBundle.cmux), "but the app is still brought to the front")
    var bg = Session(sessionId: "b1", name: "bg", cwd: "/tmp", kind: .background, state: .idle)
    bg.terminal = cmuxEnv          // a background agent's env is where it was started, not where it is shown
    bg.hostPid = nil
    ran = []
    _ = engine.jump(bg)
    check(!ran.contains(openPlan(cmuxEnv, HostFacts()).steps[1]), "a background agent never jumps by its launch env")
}

/// tmux for real, on a private server (-L), never the user's: Open selects the agent's window and pane.
func liveTmuxTest() {
    guard let tmux = tmuxBin else { return print("SKIP live tmux: tmux not installed") }
    if sandboxed { return print("SKIP live tmux: a sandboxed shell can't run a tmux server") }
    let name = "crewshelf-test-\(getpid())"
    let base = ["-L", name, "-f", "/dev/null"]
    defer { _ = run(tmux, base + ["kill-server"], timeout: 5) }
    guard run(tmux, base + ["new-session", "-d", "-s", "agents", "-x", "80", "-y", "20", "sleep 60"], timeout: 5).ok else {
        return check(false, "live tmux: could not start a private server")
    }
    let pane = run(tmux, base + ["display-message", "-p", "-t", "agents:0", "#{pane_id}"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = run(tmux, base + ["new-window", "-t", "agents", "sleep 60"], timeout: 5)
    let sockPath = run(tmux, base + ["display-message", "-p", "#{socket_path}"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
    eq(run(tmux, base + ["display-message", "-p", "-t", "agents", "#{window_index}"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines),
       "1", "live tmux: window 1 is current before Open")
    var s = Session(sessionId: "t1", name: "tmux-agent", cwd: "/tmp", kind: .interactive, state: .blocked)
    s.terminal = TerminalEnv(vars: ["TMUX": "\(sockPath),1,0", "TMUX_PANE": pane, "TERM_PROGRAM": "tmux"])
    let engine = Engine(claudeDir: tmpBase + "no-claude")
    let r = engine.jump(s)
    check(r.ok, "live tmux: Open ran (\(r.message))")
    eq(run(tmux, base + ["display-message", "-p", "-t", "agents", "#{window_index}"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines),
       "0", "live tmux: Open selected the agent's window")
}

/// The fallback's parent walk on this very process: the app it runs under is the one LaunchServices named.
func liveOwnerTest() {
    guard let want = ProcessInfo.processInfo.environment["__CFBundleIdentifier"], !want.isEmpty else {
        return print("SKIP live owner walk: not started from an app")
    }
    if sandboxed { return print("SKIP live owner walk: a sandboxed shell can't read other processes' paths") }
    let owner = ownerApp(parents: ancestry(Int(getpid())), path: processPath, bundleId: bundleIdentifier)
    eq(owner?.bundleId, want, "live: the owning app found by walking parents")
    var f = HostFacts()
    f.owner = owner
    let p = openPlan(envFixture(["TERM_PROGRAM": "vscode"], pid: Int(getpid())), f)
    eq(p.steps, [.activate(bundleId: want)], "live: the fallback activates that app")
}

func hookTermTests() {
    let line = hookRequestLine(event: "SessionStart", input: ["session_id": "s1"], decide: false, deadline: nil, terminal: true, term: cmuxEnv)
    let obj = line.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    eq(TerminalEnv(wire: obj?["term"]), cmuxEnv, "the hook sends its terminal")
    let text = line.map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(!text.contains("hunter2") && !text.contains("v1.secret"), "no secret leaves the hook")
    let hc = HookCenter()
    hc.handleEvent("SessionStart", input: ["session_id": "s1", "cwd": "/tmp"], term: cmuxEnv)
    hc.handleEvent("PreToolUse", input: ["session_id": "s1", "cwd": "/tmp", "tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "t"])
    let merged = mergeHookSessions([], hooks: hc.snapshot().sessions, pending: [])
    eq(merged.first?.terminal, cmuxEnv, "the terminal from SessionStart stays with the session")
    eq(hc.eventsSeen, 2, "events counted for the first-run notice")
    _ = hc.handle(HookConnection(local: { _ in }), ["v": hookWireVersion, "kind": "event", "event": "Stop",
                                                    "input": ["session_id": "s2"], "term": itermEnv.wire])
    eq(mergeHookSessions([], hooks: hc.snapshot().sessions, pending: []).first { $0.sessionId == "s2" }?.terminal, itermEnv,
       "the socket path stores it too")
    eq(hc.eventsSeen, 3, "socket events count")
    _ = hc.handle(HookConnection(local: { _ in }), ["v": hookWireVersion, "kind": "ctl", "op": "list"])
    eq(hc.eventsSeen, 3, "--ctl does not count as a hook event")

    // Demo: a control-only center ignores hook traffic.
    let demoCenter = HookCenter()
    demoCenter.controlOnly = true
    _ = demoCenter.handle(HookConnection(local: { _ in }), ["v": hookWireVersion, "kind": "event", "event": "SessionStart", "input": ["session_id": "real"]])
    var heldDecision = false
    _ = demoCenter.handle(HookConnection(local: { _ in heldDecision = true }),
                          ["v": hookWireVersion, "kind": "decide", "event": "PermissionRequest", "deadline": Date().addingTimeInterval(60).timeIntervalSince1970,
                           "input": ["session_id": "real", "tool_name": "Bash", "tool_input": ["command": "rm -rf /"]]])
    check(demoCenter.snapshot().sessions.isEmpty && demoCenter.snapshot().pending.isEmpty && demoCenter.eventsSeen == 0,
          "demo: real hook events and requests are never taken in")
    check(!heldDecision, "demo: and never answered")
    var replies: [String] = []
    _ = demoCenter.handle(HookConnection(local: { replies.append(($0?["ok"] as? Bool) == true ? "ok" : "no") }),
                          ["v": hookWireVersion, "kind": "ctl", "op": "list"])
    eq(replies, ["ok"], "demo: --ctl still answers")

    // In-process connections: one reply or one release, never both.
    var got: [String] = []
    let c = HookConnection(local: { got.append(($0?["decision"] as? String) ?? "released") })
    check(c.respond(["decision": "deny"]), "local respond")
    c.release()
    check(!c.respond(["decision": "allow"]), "a closed local connection takes nothing more")
    eq(got, ["deny"], "local: exactly one outcome")
}

func demoTests() {
    // Environment: never the real support folder or settings.
    let real = crewshelfSupportDir(env: [:])
    let e1 = demoEnvironment([:], tmp: "/tmp/x")
    eq(e1["CREWSHELF_SUPPORT_DIR"], "/tmp/x/crewshelf-demo-\(getuid())", "demo: its own folder")
    eq(e1["CREWSHELF_DEFAULTS"], "io.github.aaliismail.crewshelf.demo", "demo: its own settings")
    eq(e1["CREWSHELF_NO_ROSTER"], "1", "demo: no claude agents roster")
    eq(e1["CREWSHELF_QUIET"], "1", "demo: no sounds or banners")
    eq(demoEnvironment(["CREWSHELF_SUPPORT_DIR": real], tmp: "/tmp/x")["CREWSHELF_SUPPORT_DIR"], "/tmp/x/crewshelf-demo-\(getuid())",
       "demo: the real folder is refused even when asked for")
    eq(demoEnvironment(["CREWSHELF_SUPPORT_DIR": "/tmp/mine", "CREWSHELF_DEFAULTS": "x.y"])["CREWSHELF_SUPPORT_DIR"], nil, "demo: a test folder is kept")
    eq(demoEnvironment(["CREWSHELF_DEFAULTS": "io.github.aaliismail.crewshelf"])["CREWSHELF_DEFAULTS"], "io.github.aaliismail.crewshelf.demo", "demo: the real suite is refused")

    // Fake data only.
    eq(demoAgents.count, 5, "five demo agents")
    check(demoAgents.allSatisfy { $0.cwd.hasPrefix("/Users/demo/") }, "demo paths are made up")
    let dumpText = demoAgents.map { "\($0)" }.joined()
    check(!dumpText.contains(NSUserName()) && !dumpText.contains(NSHomeDirectory()), "no real user name or home in the demo")

    // The loop: drive it with a fake clock and answer what it asks.
    let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    let hc = HookCenter()
    let d = DemoDriver(hooks: hc, now: t0)
    eq(d.roster(now: t0).count, 5, "five on the shelf")
    eq(Set(d.roster(now: t0).map { $0.kind }), [.interactive, .background], "tabs and a background agent")
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func shelf(_ s: Double) -> [Session] {
        let snap = hc.snapshot()
        return mergeHookSessions(d.roster(now: at(s)), hooks: snap.sessions, pending: snap.pending)
    }
    var t = 0.0
    func until(_ limit: Double, _ cond: () -> Bool) -> Bool {
        while t < limit { t += 0.25; d.tick(now: at(t)); if cond() { return true } }
        return false
    }
    check(until(15) { hc.snapshot().pending.contains { $0.toolName == "Bash" } }, "a permission request comes up")
    let perm = hc.snapshot().pending.first { $0.toolName == "Bash" }!
    eq(d.agents[d.index(of: perm.sessionId)!].name, "rate-limit", "from rate-limit")
    check(perm.hasTerminal && perm.preview.body.contains("npm test"), "with a realistic command and Answer in terminal")
    let looks = Set(shelf(t).map { look(for: $0) })
    check(looks.isSuperset(of: [.working, .blocked, .idle]), "working, waiting and idle side by side: \(looks)")
    check(hc.snapshot().sessions.contains { $0.doneAt != nil }, "and one done")
    check(until(20) { hc.snapshot().pending.contains { $0.kind == .question } }, "a question comes up too")
    let q = hc.snapshot().pending.first { $0.kind == .question }!
    eq(q.questions.first?.options.map { $0.label } ?? [], ["Own tab", "Inside Account", "Modal"], "with options")

    // Buttons work on the fake requests.
    let now = at(t)
    if case .failure(let e) = hc.decide(perm.id, HookDecision(.allow), now: now) { check(false, "demo approve: \(e)") }
    if case .failure(let e) = hc.decide(q.id, HookDecision(.answer, answers: [q.questions[0].question: "Own tab"]), now: now) {
        check(false, "demo answer: \(e)")
    }
    d.tick(now: at(t + 0.25)); t += 0.25
    check(hc.snapshot().pending.isEmpty, "answered requests are gone")
    check(until(t + 6) { hc.snapshot().sessions.first { $0.sessionId == perm.sessionId }?.lastMessage?.contains("limiter") == true },
          "approved: rate-limit carries on and finishes")
    check(until(t + 30) { hc.snapshot().pending.contains { $0.toolName == "Edit" } }, "deploy-docs asks to edit a file")
    let edit = hc.snapshot().pending.first { $0.toolName == "Edit" }!
    eq(edit.preview.style, .diff, "shown as a diff")
    _ = hc.decide(edit.id, HookDecision(.deny), now: at(t))
    d.tick(now: at(t + 0.25)); t += 0.25
    check(hc.snapshot().sessions.first { $0.sessionId == edit.sessionId }?.lastMessage?.contains("won't run") == true, "denied: it stops and says so")

    // Unanswered: let go after the timeout, as if answered in the terminal.
    check(until(t + 120) { !hc.snapshot().pending.isEmpty }, "the loop asks again")
    let again = hc.snapshot().pending.first!
    check(until(t + d.answerTimeout + 5) { !hc.snapshot().pending.contains { $0.id == again.id } }, "an unanswered demo request is let go")

    // End / Hide: it leaves and comes back.
    let gone = d.agents[4].id
    d.end(gone, now: at(t))
    check(!d.roster(now: at(t)).contains { $0.sessionId == gone }, "ended: off the roster")
    check(until(t + d.restartAfter + 2) { d.roster(now: at(t)).contains { $0.sessionId == gone } }, "and back a little later")

    // Frozen: nothing moves (for screenshots).
    d.frozen = true
    let before = hc.snapshot().sessions.map { $0.lastEventAt }.max()
    for _ in 0..<40 { t += 0.25; d.tick(now: at(t)) }
    eq(hc.snapshot().sessions.map { $0.lastEventAt }.max(), before, "frozen: no events")
}

func settingsTests() {
    let home = "/Users/someone"
    check(launchAtLoginAllowed(bundlePath: "/Applications/Crewshelf.app", home: home), "login item: /Applications")
    check(launchAtLoginAllowed(bundlePath: "/Users/someone/Applications/Crewshelf.app", home: home), "login item: ~/Applications")
    check(launchAtLoginAllowed(bundlePath: "/Applications/Utilities/Crewshelf.app", home: home), "login item: a folder in Applications")
    check(!launchAtLoginAllowed(bundlePath: "/Users/someone/crewshelf/build/Crewshelf.app", home: home), "login item: not from a build folder")
    check(!launchAtLoginAllowed(bundlePath: "/Users/someone/Downloads/Crewshelf.app", home: home), "login item: not from Downloads")
    check(!launchAtLoginAllowed(bundlePath: "/Applications/../tmp/Crewshelf.app", home: home), "login item: .. does not fool it")
    check(!launchAtLoginAllowed(bundlePath: "/ApplicationsX/Crewshelf.app", home: home), "login item: a look-alike folder")

    let w = mk("w", .working), i = mk("i", .idle), b = mk("b", .blocked), gone = mk("g", .idle, raw: "stopped"), c = mk("c", .idle)
    eq(shownOnShelf([w, i, b, gone, c], hideIdle: false, keep: []).map { $0.sessionId }, ["w", "i", "b", "g", "c"], "hide idle off: everyone")
    eq(shownOnShelf([w, i, b, gone, c], hideIdle: true, keep: ["c"]).map { $0.sessionId }, ["w", "b", "c"],
       "hide idle: working, waiting, and an idle one with a check or an open bubble")

    let suite = "io.github.aaliismail.crewshelf.tests.p3.\(getpid())"
    if let dflt = UserDefaults(suiteName: suite) {
        let p = ShelfPrefs(defaults: dflt)
        check(!p.pluginSeen && !p.hideIdle, "first run: plugin not seen, idle agents shown")
        p.pluginSeen = true
        p.hideIdle = true
        let again = ShelfPrefs(defaults: UserDefaults(suiteName: suite)!)
        check(again.pluginSeen && again.hideIdle, "both settings read back")
        dropSuite(suite)
    }
    eq(ShelfSpot.corner("D", .left, .top), ShelfSpot(display: "D", h: .left, v: .top, dx: shelfMargin, dy: shelfMargin), "corner spot")
    check(ShelfSpot.corner("D", .left, .top).corner.map { $0 == (.left, .top) } == true, "a corner spot knows its corner")
    check(ShelfSpot(display: "D", h: .left, v: .top, dx: 300, dy: 10).corner == nil, "a dragged spot is in no corner")
    eq(pluginInstallCommands, ["/plugin marketplace add aaliismail/crewshelf", "/plugin install crewshelf@crewshelf"], "first-run commands")
}

func displayTests() {
    let main = DisplayInfo(id: "MAIN", frame: CGRect(x: 0, y: 0, width: 1920, height: 1055), isMain: true)
    let above = DisplayInfo(id: "TOP", frame: CGRect(x: 200, y: 1080, width: 1440, height: 875), isMain: false)
    let left = DisplayInfo(id: "LEFT", frame: CGRect(x: -2560, y: -300, width: 2560, height: 1415), isMain: false)
    let all = [main, above, left]
    let size = CGSize(width: 260, height: 70)
    for (d, drop) in [(above, CGRect(x: 1300, y: 1100, width: 260, height: 70)), (left, CGRect(x: -400, y: -280, width: 260, height: 70))] {
        let s = dropSpot(drop, displays: all)!
        eq(s.display, d.id, "dragged onto \(d.id): the spot belongs to it")
        let fr = shelfFrame(spot: s, size: size, displays: all)!.frame
        check(d.frame.contains(fr), "and the shelf is placed on it")
        eq(display(for: fr, in: all)?.id, d.id, "the bubble opens on that display")
        let pl = bubblePlacement(shelf: fr, anchorX: fr.midX, size: CGSize(width: 316, height: 300), screen: d.frame)
        check(d.frame.contains(pl.frame), "the bubble stays inside \(d.id): \(pl.frame)")
    }
    let straddle = CGRect(x: -100, y: 400, width: 260, height: 70)      // center on main
    eq(display(for: straddle, in: all)?.id, "MAIN", "a shelf across two displays belongs to the one holding its center")
    eq(shelfFrame(spot: ShelfSpot.corner("TOP", .left, .top), size: size, displays: all)!.frame,
       CGRect(x: 210, y: 1080 + 875 - 10 - 70, width: 260, height: 70), "Corner > Top left on the upper display")
}

/// The Open scripts compile against the dictionary of each installed terminal, and every term resolves to that
/// terminal's own four-letter code (a word the dictionary lacks would compile as a plain variable and only fail
/// when Open runs). Compiling needs no Automation permission and runs nothing.
func appleScriptCompileTests() {
    let cases: [(name: String, app: String, script: String, codes: [String])] = [
        ("Terminal", "/System/Applications/Utilities/Terminal.app", AppleTerminalAdapter.script(tty: "ttys003"),
         ["ttab", "ttty", "tbsl"]),
        ("Ghostty", "/Applications/Ghostty.app", GhosttyAdapter.script(cwd: "/Users/demo/code/api \"quoted\" \\ dir"),
         ["Gtrm", "Gwdr", "Fcus"]),
        ("iTerm2", "/Applications/iTerm.app", ITermAdapter.script(sessionId: "6B2E8F1A-1D3C-4E5F-8A9B-0C1D2E3F4A5B", tty: "ttys005"),
         ["Trmt", "Trms", "Uniq", "Stty", "slct"]),
    ]
    for c in cases {
        guard FileManager.default.fileExists(atPath: c.app) else {
            print("SKIP \(c.name) AppleScript compile: \(c.app) is not installed")
            continue
        }
        let out = tmpBase + "crewshelf-osa-\(getpid()).scpt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        let lines = c.script.split(separator: "\n").flatMap { ["-e", String($0)] }
        let r = run("/usr/bin/osacompile", ["-o", out] + lines, timeout: 20)
        guard r.ok, let data = FileManager.default.contents(atPath: out) else {
            check(false, "\(c.name) Open script compiles: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            continue
        }
        for code in c.codes {
            check(data.range(of: Data(code.utf8)) != nil, "\(c.name) Open script: a term resolves to its dictionary code '\(code)'")
        }
    }
}

/// Nothing in the repo names this Mac's user: no home path, no account name in a path, no per-user temp folder
/// (screenshots and GIFs included, byte for byte). Example paths use /Users/demo, /Users/a, /Users/x, /Users/someone.
func privacyTests() {
    let root = ((fixtures as NSString).appendingPathComponent("../..") as NSString).standardizingPath
    let fm = FileManager.default
    var files: [String] = ["README.md", "SECURITY.md", "CONTRIBUTING.md", "CHANGELOG.md", "LICENSE", "build.sh",
                           "install.sh", "uninstall.sh", ".gitignore"].map { root + "/" + $0 }
    for dir in ["Sources", "Tests", "plugin", "docs", ".claude-plugin", ".github"] {
        guard let e = fm.enumerator(atPath: root + "/" + dir) else { continue }
        for case let f as String in e { files.append(root + "/" + dir + "/" + f) }
    }
    files += ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasSuffix(".png") || $0.hasSuffix(".gif") }.map { root + "/" + $0 }
    var tmp = [CChar](repeating: 0, count: 1024)
    let userTemp = confstr(_CS_DARWIN_USER_TEMP_DIR, &tmp, tmp.count) > 0 ? String(cString: tmp) : ""
    var needles = [NSHomeDirectory() + "/", "/Users/" + NSUserName() + "/"]
    let tparts = userTemp.split(separator: "/")          // var/folders/<xx>/<per-user hash>/T
    if let i = tparts.firstIndex(of: "folders"), tparts.count > i + 2, tparts[i + 2].count >= 16 { needles.append(String(tparts[i + 2])) }
    let allowedHomes: Set<String> = ["demo", "a", "x", "someone", "Shared"]
    var scanned = 0
    for f in files {
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: f, isDirectory: &dir), !dir.boolValue, let d = fm.contents(atPath: f) else { continue }
        scanned += 1
        let name = String(f.dropFirst(root.count + 1))
        for n in Set(needles) where d.range(of: Data(n.utf8)) != nil {
            check(false, "\(name) holds this Mac's \(n.hasPrefix("/Users") ? "home path" : "temp folder") \(n)")
        }
        let text = String(decoding: d, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: "/Users/([A-Za-z0-9._-]+)") else { continue }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let who = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !allowedHomes.contains(who) else { continue }
            check(false, "\(name) holds a real-looking home path /Users/\(who)")
        }
    }
    check(scanned > 40, "privacy scan read the repo (\(scanned) files)")
}

func runP3Tests() {
    privacyTests()
    appleScriptCompileTests()
    terminalTests()
    liveTmuxTest()
    liveOwnerTest()
    hookTermTests()
    demoTests()
    settingsTests()
    displayTests()
}
