import Foundation

// Calls answered outside Crewshelf, terminal vs no-terminal sessions, the decision cutoff, --ctl gating, previews that
// hide nothing, the arm delay and the server's held-connection loop. Each block is a defect a checker found in P1.

let tabEnv = ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "1"]

func withTab(_ env: [String: String]) -> [String: String] { env.merging(tabEnv) { _, b in b } }

func appendLine(_ path: String, _ line: String) {
    guard let fh = FileHandle(forWritingAtPath: path) else { return }
    fh.seekToEndOfFile()
    fh.write(Data((line + "\n").utf8))
    try? fh.close()
}

func isoNow(_ d: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

func toolResultLine(_ id: String, error: Bool) -> String {
    #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"The user doesn't want to proceed with this tool use."}]},"timestamp":"\#(isoNow())"}"#
}

func interruptLine(_ at: Date = Date()) -> String {
    #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"\#(isoNow(at))"}"#
}

/// A PermissionRequest input for a session with a transcript, plus its PreToolUse twin.
func callInputs(_ sid: String, _ tuid: String, _ cmd: String, transcript: String, agent: String? = nil) -> (pre: [String: Any], perm: [String: Any]) {
    var base: [String: Any] = ["session_id": sid, "cwd": "/tmp/proj", "transcript_path": transcript, "permission_mode": "default",
                               "tool_name": "Bash", "tool_input": ["command": cmd, "description": "test"]]
    if let a = agent { base["agent_id"] = a }
    var pre = base, perm = base
    pre["hook_event_name"] = "PreToolUse"; pre["tool_use_id"] = tuid
    perm["hook_event_name"] = "PermissionRequest"
    return (pre, perm)
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func resolveTests() {
    let (srv, c, env) = startServer("rs")
    defer { srv.stop() }
    let tx = env["CREWSHELF_SUPPORT_DIR"]! + "/t.jsonl"
    FileManager.default.createFile(atPath: tx, contents: Data(#"{"type":"user","message":{"content":"old history"}}"#.utf8 + [10]))
    let json = { (o: [String: Any]) in canonicalJSON(o)! }

    // 1. Allowed or denied in the terminal: the call's tool_result lands in the transcript, nothing else may fire
    //    (a terminal "No" sends no PostToolUse and no Stop). The held request is released with no output, its
    //    step is finished, and the session goes idle on the interrupt.
    var (pre, perm) = callInputs("rs-1", "tu-7", "echo one", transcript: tx)
    _ = runHook(argv: ["UserPromptSubmit"], stdin: Data(json(["session_id": "rs-1", "transcript_path": tx, "prompt": "go"]).utf8), env: withTab(env))
    usleep(20_000)
    _ = runHook(argv: ["PreToolUse"], stdin: Data(json(pre).utf8), env: withTab(env))
    var wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], json(perm), withTab(env))
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "tab request pending")
    var req = c.snapshot().pending.first
    eq(req?.stepId ?? "nil", "tu-7", "request matched to its tool_use_id")
    eq(req?.hasTerminal, true, "tab request knows it has a terminal")
    check(c.reconcile() == false, "nothing new in the transcript: nothing changes")
    check(c.snapshot().pending.count == 1, "…and the request stays")
    appendLine(tx, toolResultLine("tu-7", error: true))
    appendLine(tx, interruptLine())
    check(c.reconcile(), "transcript shows the call was answered in the terminal")
    var (out, secs) = wait()
    check(out == nil && secs < 3, "answered in the terminal: the held hook prints nothing and exits at once")
    check(c.snapshot().pending.isEmpty, "answered in the terminal: no stale bubble")
    let hs = c.snapshot().sessions.first { $0.sessionId == "rs-1" }
    check(hs?.working == false && hs?.inTerminal == false, "terminal No: the session is idle, not stuck working")
    check(hs?.steps.first { $0.step.id == "tu-7" }.map { !$0.step.pending && $0.step.isError } == true, "terminal No: step finished as refused")
    if let r = req, case .failure(let e) = c.decide(r.id, HookDecision(.allow)) { eq(e, .answeredElsewhere, "Approve after a terminal answer is refused as answered elsewhere") }
    else { check(false, "Approve after a terminal answer must fail") }

    // 2. The stale request must not hide the real one, and Approve must not land on a call Claude stopped
    //    listening to. Two calls in a row: the first answered in the terminal (decide catches up on the
    //    transcript itself, before the timer does), the second is the one Approve reaches.
    (pre, perm) = callInputs("rs-1", "tu-8", "echo two", transcript: tx)
    _ = runHook(argv: ["UserPromptSubmit"], stdin: Data(json(["session_id": "rs-1", "transcript_path": tx, "prompt": "again"]).utf8), env: withTab(env))
    _ = runHook(argv: ["PreToolUse"], stdin: Data(json(pre).utf8), env: withTab(env))
    let first = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], json(perm), withTab(env))
    check(waitFor(3) { c.snapshot().pending.count == 1 }, "first request pending")
    let firstId = c.snapshot().pending.first?.id ?? ""
    appendLine(tx, toolResultLine("tu-8", error: false))      // approved in the terminal; PostToolUse not here yet
    let (pre2, perm2) = callInputs("rs-1", "tu-9", "echo three", transcript: tx)
    _ = runHook(argv: ["PreToolUse"], stdin: Data(json(pre2).utf8), env: withTab(env))
    let second = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], json(perm2), withTab(env))
    check(waitFor(3) { c.snapshot().pending.count == 2 }, "second request pending")
    if case .failure(let e) = c.decide(firstId, HookDecision(.allow)) { eq(e, .answeredElsewhere, "Approve on the stale request: refused, nothing sent") }
    else { check(false, "Approve on a call answered in the terminal must not report success") }
    check(first().0 == nil, "stale request's hook prints nothing")
    eq(c.snapshot().pending.map { $0.stepId ?? "" }, ["tu-9"], "the real request is now first in the bubble")
    if let r = c.snapshot().pending.first { if case .failure(let e) = c.decide(r.id, HookDecision(.allow)) { check(false, "second allow: \(e)") } }
    check(outText(second().0)?.contains("\"behavior\":\"allow\"") == true, "Approve reaches the real request")

    // An interrupt older than the latest prompt is history, not a reason to go idle.
    _ = runHook(argv: ["UserPromptSubmit"], stdin: Data(json(["session_id": "rs-1", "transcript_path": tx, "prompt": "more"]).utf8), env: withTab(env))
    appendLine(tx, interruptLine(Date().addingTimeInterval(-30)))
    c.reconcile()
    check(c.snapshot().sessions.first { $0.sessionId == "rs-1" }?.working == true, "old interrupt ignored after a new prompt")

    // 3. A tab's question: PreToolUse does not hold it (the terminal shows it at once); its PermissionRequest
    //    is held instead, alongside the terminal dialog, and answered there with updatedInput.answers.
    var ask = jsonObj(askInput)
    ask["session_id"] = "rs-q"; ask["transcript_path"] = tx; ask["tool_use_id"] = "tu-q"
    let t0 = Date()
    check(runHook(argv: ["PreToolUse", "--decide", "--timeout", "590"], stdin: Data(json(ask).utf8), env: withTab(env)) == nil,
          "tab question: PreToolUse prints nothing")
    check(Date().timeIntervalSince(t0) < 1, "tab question: PreToolUse returns at once")
    check(waitFor(2) { c.snapshot().sessions.first { $0.sessionId == "rs-q" }?.steps.contains { $0.step.id == "tu-q" } == true },
          "tab question: the step still shows")
    check(c.snapshot().pending.isEmpty, "tab question: nothing held at PreToolUse")
    var askPR = ask
    askPR["hook_event_name"] = "PermissionRequest"; askPR.removeValue(forKey: "tool_use_id")
    wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], json(askPR), withTab(env))
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "tab question held at its PermissionRequest")
    req = c.snapshot().pending.first
    eq(req?.kind, .question, "…as a question")
    eq(req?.stepId ?? "nil", "tu-q", "…matched to its step")
    if let r = req, case .failure(let e) = c.decide(r.id, HookDecision(.answer, answers: ["Which framework?": "Vue", "Which extras?": "CI"])) {
        check(false, "tab answer: \(e)")
    }
    (out, _) = wait()
    let pr = (jsonObj(outText(out) ?? "")["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    eq(pr?["behavior"] as? String, "allow", "tab question answered through PermissionRequest")
    eq(((pr?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) ?? [:],
       ["Which framework?": "Vue", "Which extras?": "CI"], "…with the answers")

    // 4. A no-terminal question handed to the terminal is not asked a second time by its own PermissionRequest.
    var bgAsk = jsonObj(askInput)
    bgAsk["session_id"] = "rs-bg"; bgAsk["tool_use_id"] = "tu-bgq"
    wait = hookAsync(["PreToolUse", "--decide", "--timeout", "30"], json(bgAsk), env)
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "no-terminal question held at PreToolUse")
    req = c.snapshot().pending.first
    eq(req?.hasTerminal, false, "…and knows there is no terminal")
    if let r = req { _ = c.decide(r.id, HookDecision(.terminal)) }
    check(wait().0 == nil, "terminal hand-off prints nothing")
    var bgPR = bgAsk
    bgPR["hook_event_name"] = "PermissionRequest"; bgPR.removeValue(forKey: "tool_use_id")
    let t1 = Date()
    check(runHook(argv: ["PermissionRequest", "--decide", "--timeout", "30"], stdin: Data(json(bgPR).utf8), env: env) == nil,
          "the same call's PermissionRequest prints nothing")
    check(Date().timeIntervalSince(t1) < 1 && c.snapshot().pending.isEmpty, "…at once, with no second bubble")

    // 5. Subagents: the main agent's Stop leaves a subagent's request alone; SubagentStop releases it.
    let (_, subPerm) = callInputs("rs-1", "tu-s", "echo sub", transcript: tx, agent: "ag-1")
    wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], json(subPerm), withTab(env))
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "subagent request pending")
    c.handleEvent("Stop", input: ["session_id": "rs-1", "last_assistant_message": "main done"])
    check(c.snapshot().pending.count == 1, "main Stop keeps the subagent's request")
    c.handleEvent("SubagentStop", input: ["session_id": "rs-1", "agent_id": "ag-1"])
    check(wait().0 == nil && c.snapshot().pending.isEmpty, "SubagentStop releases it with no output")

    // 6. idle_prompt: a minute after the turn, nothing is running; any leftover main request is stale.
    let (_, idlePerm) = callInputs("rs-1", "tu-i", "echo idle", transcript: tx)
    c.handleEvent("UserPromptSubmit", input: ["session_id": "rs-1"])
    wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], json(idlePerm), withTab(env))
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "request before idle_prompt")
    c.handleEvent("Notification", input: ["session_id": "rs-1", "notification_type": "idle_prompt"])
    check(wait().0 == nil && c.snapshot().pending.isEmpty, "idle_prompt releases it")
    check(c.snapshot().sessions.first { $0.sessionId == "rs-1" }?.working == false, "idle_prompt: not working")

    // 7. The decision cutoff: the app stops taking decisions before the hook stops listening, so a decision it
    //    accepts always arrives, and one it can't deliver is refused (never "Approved." with nothing applied).
    wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], bashInput, env)   // hook gives up at 24 s
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "cutoff request pending")
    req = c.snapshot().pending.first
    if let r = req {
        let hookGivesUp = r.createdAt.addingTimeInterval(24)
        check(abs(hookGivesUp.timeIntervalSince(r.deadline) - 2) < 0.5, "decisions close 2 s before the hook gives up")
        if case .failure(let e) = c.decide(r.id, HookDecision(.allow), now: hookGivesUp.addingTimeInterval(-1)) {
            eq(e, .expired, "1 s before the hook gives up: refused, not reported as approved")
        } else { check(false, "a decision too late to deliver must fail") }
    }
    check(wait().0 == nil, "refused late decision: the hook prints nothing")
    // Short timeout, decided just inside the cutoff: it still reaches the hook.
    wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "4"], bashInput, env)      // gives up at 3.2 s
    check(waitFor(2) { !c.snapshot().pending.isEmpty }, "short request pending")
    if let r = c.snapshot().pending.first {
        while Date() < r.deadline.addingTimeInterval(-0.15) { usleep(10_000) }
        if case .failure(let e) = c.decide(r.id, HookDecision(.allow)) { check(false, "just-in-time allow: \(e)") }
    }
    check(outText(wait().0)?.contains("\"behavior\":\"allow\"") == true, "a decision accepted at the cutoff is delivered")

    // 8. --ctl decide/answer are off unless the app runs with CREWSHELF_TEST_CONTROL=1.
    c.allowControlDecisions = false
    wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], bashInput, env)
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "ctl-gate request pending")
    let path = env["CREWSHELF_SUPPORT_DIR"]! + "/crewshelf.sock"
    func ctl(_ o: [String: Any]) -> [String: Any] {
        jsonObj(outText(socketRequest(path: path, line: Data((canonicalJSON(o)! + "\n").utf8), connectBy: Date().addingTimeInterval(1),
                                      writeBy: Date().addingTimeInterval(2), replyBy: Date().addingTimeInterval(3))) ?? "")
    }
    let id = c.snapshot().pending.first?.id ?? ""
    let refused = ctl(["v": 1, "kind": "ctl", "op": "decide", "id": id, "decision": "allow"])
    eq(refused["ok"] as? Bool, false, "ctl decide refused by default")
    eq(refused["error"] as? String, DecideError.controlOff.rawValue, "…saying test control is off")
    eq(ctl(["v": 1, "kind": "ctl", "op": "answer", "id": id, "answers": ["a": "b"]])["ok"] as? Bool, false, "ctl answer refused by default")
    check(c.snapshot().pending.count == 1, "…and the request is untouched")
    eq(ctl(["v": 1, "kind": "ctl", "op": "list"])["ok"] as? Bool, true, "ctl list still works")
    var uiCalls: [String] = []
    c.uiControl = { o in uiCalls.append(o["op"] as? String ?? ""); return ["ok": true] }
    for op in ["tap", "open"] {
        let r = ctl(["v": 1, "kind": "ctl", "op": op, "session": "x"])
        eq(r["ok"] as? Bool, false, "ctl \(op) refused by default")
        eq(r["error"] as? String, DecideError.controlOff.rawValue, "…ctl \(op) says test control is off")
    }
    eq(uiCalls, [], "…and never reaches the UI")
    eq(ctl(["v": 1, "kind": "ctl", "op": "plan", "session": "x"])["ok"] as? Bool, true, "ctl plan (read only) still reaches the UI")
    c.allowControlDecisions = true
    eq(ctl(["v": 1, "kind": "ctl", "op": "tap", "session": "x"])["ok"] as? Bool, true, "with test control on, ctl tap works")
    eq(uiCalls, ["plan", "tap"], "…through the UI hook")
    c.uiControl = { _ in nil }
    eq(ctl(["v": 1, "kind": "ctl", "op": "decide", "id": id, "decision": "deny"])["ok"] as? Bool, true, "with test control on, ctl decides")
    check(outText(wait().0)?.contains("\"behavior\":\"deny\"") == true, "…through the same decide")

    // 9. Bytes after the request line don't spin the server's held-connection loop.
    if let fd = unixConnect(path, deadline: Date().addingTimeInterval(1)) {
        let line = hookRequestLine(event: "PermissionRequest", input: jsonObj(bashInput), decide: true, deadline: Date().addingTimeInterval(30))!
        _ = writeAll(fd, line, deadline: Date().addingTimeInterval(1))
        check(waitFor(2) { !c.snapshot().pending.isEmpty }, "request with trailing bytes pending")
        _ = writeAll(fd, Data("trailing junk the client sends after its request line".utf8), deadline: Date().addingTimeInterval(1))
        let cpu0 = cpuSeconds(), wall0 = Date()
        usleep(1_000_000)
        let used = cpuSeconds() - cpu0
        check(used < 0.3, "held request with trailing bytes uses no CPU (\(String(format: "%.2f", used)) s in \(String(format: "%.1f", Date().timeIntervalSince(wall0))) s)")
        close(fd)
        check(waitFor(2) { c.snapshot().pending.isEmpty }, "…and is released when the client goes")
    }

    // 10. Merge: a hooked -p session is labelled headless even though `claude agents` lists it like a tab.
    var listed = Session(sessionId: "p-1", name: "p", cwd: "/tmp/p", kind: .interactive, state: .idle)
    listed.pid = 5
    c.handleEvent("SessionStart", input: ["session_id": "p-1", "cwd": "/tmp/p"], terminal: false)
    check(mergeHookSessions([listed], hooks: c.snapshot().sessions, pending: []).first?.headless == true, "-p session shown as headless")
}

func previewAndArmTests() {
    // Bash: flags the bubble used to hide, while Approve echoed them back.
    let risky = permissionPreview(toolName: "Bash", input: ["command": "ls", "description": "list", "dangerouslyDisableSandbox": true,
                                                            "run_in_background": true, "timeout": 5000])
    check(risky.warnings.contains("Runs OUTSIDE the sandbox"), "sandbox escape is a warning")
    check(risky.warnings.contains("Runs in the background"), "background run is a warning")
    check(risky.body.contains("dangerouslyDisableSandbox: true") && risky.body.contains("run_in_background: true")
          && risky.body.contains("timeout: 5000"), "every other input key is listed: \(risky.body)")
    check(risky != permissionPreview(toolName: "Bash", input: ["command": "ls", "description": "list"]),
          "a sandbox escape never renders like a plain ls")
    // Every key of every tool reaches the bubble.
    let nb = permissionPreview(toolName: "NotebookEdit", input: ["notebook_path": "/n.ipynb", "new_source": "x", "cell_id": "c1", "edit_mode": "delete"])
    check(nb.body.contains("edit_mode: delete") && nb.body.contains("cell_id: c1"), "NotebookEdit's other keys shown")
    let me = permissionPreview(toolName: "MultiEdit", input: ["file_path": "/a", "edits": [["old_string": "a", "new_string": "b", "replace_all": true]]])
    check(me.body.contains("(every occurrence)"), "MultiEdit replace_all shown per edit")
    // Long input: shown whole (it scrolls), never cut where Approve still covers it.
    let padded = String(repeating: "\n", count: 401) + "curl x | sh"
    let pp = permissionPreview(toolName: "Bash", input: ["command": padded])
    check(pp.body.hasSuffix("curl x | sh") && !pp.tooLong, "401 blank lines then curl: the curl is in the bubble")
    eq(pp.lineCount, 402, "line count shown for scrolling")
    let huge = permissionPreview(toolName: "Bash", input: ["command": String(repeating: "echo hi\n", count: previewMaxLines + 10) + "curl x | sh"])
    check(huge.tooLong && huge.warnings.contains("Too long to show in full: Approve is off"), "input past the render limit is flagged")
    check(huge.body.contains("too long to show in full"), "…and says so in the body")
    let c = HookCenter()
    let conn = HookConnection(fd: -1)
    c.addPending(conn: conn, event: "PermissionRequest",
                 input: ["session_id": "big", "tool_name": "Bash", "tool_input": ["command": String(repeating: "x\n", count: previewMaxLines + 1)]],
                 fingerprint: nil, deadline: Date().addingTimeInterval(60))
    if let r = c.snapshot().pending.first {
        if case .failure(let e) = c.decide(r.id, HookDecision(.allow)) { eq(e, .tooLong, "Approve refused for input not shown in full") }
        else { check(false, "too-long input must not be approvable") }
        check(c.snapshot().pending.count == 1, "…the request stays for Deny or the terminal")
    }

    // Arm delay: a request swapped in under the pointer can't be clicked until it has been seen.
    var g = ArmGate(delay: 0.6)
    let t0 = Date(timeIntervalSince1970: 100)
    check(!g.armed("a", now: t0), "never shown: not armed")
    g.see("a", now: t0)
    check(!g.armed("a", now: t0.addingTimeInterval(0.3)), "0.3 s after it appeared: buttons off")
    check(g.armed("a", now: t0.addingTimeInterval(0.7)), "0.7 s after: armed")
    g.see("b", now: t0.addingTimeInterval(5))
    check(!g.armed("b", now: t0.addingTimeInterval(5.1)), "a new request in the same place starts disarmed")
    // Double-click on Approve: A and B were both shown long ago; tap B, tap A, click Approve (A is answered,
    // B comes back under the pointer), click again 150 ms later. The second click must not approve B.
    g.see("a", now: t0.addingTimeInterval(10))
    check(g.armed("a", now: t0.addingTimeInterval(11)), "A shown 1 s: armed (first click approves A)")
    g.see("b", now: t0.addingTimeInterval(11.01))
    check(!g.armed("b", now: t0.addingTimeInterval(11.16)), "B, shown before and now back in A's place: disarmed for the second click")
    check(g.armed("b", now: t0.addingTimeInterval(11.7)), "…and armed once it has been on screen 0.6 s")
}

func transcriptScanTests() {
    let p = tmpBase + "crewshelf-scan-\(getpid()).jsonl"
    try? Data().write(to: URL(fileURLWithPath: p))     // not atomic: a sandboxed run may not write a temp file next to it
    appendLine(p, toolResultLine("a", error: false))
    appendLine(p, #"{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"side","content":"x"}]}}"#)
    appendLine(p, "not json tool_result")
    if let (f, off) = scanTranscript(path: p, from: 0) {
        eq(f.results, ["a": false], "tool results of the main chain only")
        eq(off, fileSize(p), "offset at the end")
        // A partial last line waits for the rest.
        if let fh = FileHandle(forWritingAtPath: p) { fh.seekToEndOfFile(); fh.write(Data(#"{"type":"user","message":{"content":[{"type":"tool_res"#.utf8)); try? fh.close() }
        if let (f2, off2) = scanTranscript(path: p, from: off) {
            check(f2.results.isEmpty && off2 == off, "partial line is not consumed")
        }
    } else { check(false, "scan reads the file") }
    check(scanTranscript(path: p + ".missing", from: 0)?.0.results.isEmpty ?? true, "missing transcript: nothing found")
    try? FileManager.default.removeItem(atPath: p)
}
