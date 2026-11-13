import Foundation

// Hook protocol, socket and fail-safe tests. Uses the real HookServer + HookCenter, the in-process hook client,
// and the built `build/crewshelf-hook` binary and `plugin/bin/crewshelf-shim` script.

/// $TMPDIR when set (sandboxed runs), else the user temp dir.
let tmpBase: String = {
    let t = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    return t.hasSuffix("/") ? t : t + "/"
}()

func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; usleep(5_000) }
    return cond()
}

func jsonObj(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

func outText(_ d: Data?) -> String? { d.map { String(decoding: $0, as: UTF8.self) } }

/// Run a program with stdin and env; returns (status, stdout, seconds). posix_spawn + waitpid, so the time is the
/// program's own wall time (Foundation's Process adds tens of ms of run-loop latency on exit).
func runTimed(_ path: String, _ args: [String], stdin: Data, env: [String: String]) -> (Int32, String, Double) {
    var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
    guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { return (-1, "pipe", 0) }
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
    posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
    for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1]] { posix_spawn_file_actions_addclose(&fa, fd) }
    let argv = ([path] + args).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) }; posix_spawn_file_actions_destroy(&fa) }
    var pid: pid_t = 0
    let t0 = Date()
    guard posix_spawn(&pid, path, &fa, nil, argv, envp) == 0 else { return (-1, "spawn", 0) }
    close(inPipe[0]); close(outPipe[1])
    stdin.withUnsafeBytes { _ = write(inPipe[1], $0.baseAddress, stdin.count) }
    close(inPipe[1])
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(outPipe[0], &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
    close(outPipe[0])
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    let secs = Date().timeIntervalSince(t0)
    let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    return (code, String(decoding: out, as: UTF8.self), secs)
}

let bashInput = """
{"session_id":"sess-1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/proj","permission_mode":"default",
 "hook_event_name":"PermissionRequest","tool_name":"Bash",
 "tool_input":{"command":"echo crewshelf-ok > /tmp/x.txt","description":"Write a file"}}
"""
let askInput = """
{"session_id":"sess-2","cwd":"/tmp/proj","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_9",
 "tool_input":{"questions":[{"question":"Which framework?","header":"Framework","multiSelect":false,
   "options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive"}]},
  {"question":"Which extras?","header":"Extras","multiSelect":true,"options":[{"label":"Tests"},{"label":"Docs"},{"label":"CI"}]}]}}
"""

func goldenTests() {
    let bash = jsonObj(bashInput), ask = jsonObj(askInput)
    eq(outText(hookOutput(event: "PermissionRequest", input: bash, decision: HookDecision(.allow))) ?? "nil",
       #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"command":"echo crewshelf-ok > /tmp/x.txt","description":"Write a file"}},"hookEventName":"PermissionRequest"}}"# + "\n",
       "golden: PermissionRequest allow echoes the tool input")
    eq(outText(hookOutput(event: "PermissionRequest", input: bash, decision: HookDecision(.deny))) ?? "nil",
       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"The user denied this in Crewshelf."},"hookEventName":"PermissionRequest"}}"# + "\n",
       "golden: PermissionRequest deny")
    eq(outText(hookOutput(event: "PermissionRequest", input: bash, decision: HookDecision(.deny, message: "not now"))) ?? "nil",
       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"not now"},"hookEventName":"PermissionRequest"}}"# + "\n",
       "golden: PermissionRequest deny with message")
    let answers = ["Which framework?": "React", "Which extras?": "Tests, CI"]
    let q = "[{\"header\":\"Framework\",\"multiSelect\":false,\"options\":[{\"description\":\"Component library\",\"label\":\"React\"},{\"description\":\"Progressive\",\"label\":\"Vue\"}],\"question\":\"Which framework?\"},{\"header\":\"Extras\",\"multiSelect\":true,\"options\":[{\"label\":\"Tests\"},{\"label\":\"Docs\"},{\"label\":\"CI\"}],\"question\":\"Which extras?\"}]"
    eq(outText(hookOutput(event: "PreToolUse", input: ask, decision: HookDecision(.answer, answers: answers))) ?? "nil",
       "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"answers\":{\"Which extras?\":\"Tests, CI\",\"Which framework?\":\"React\"},\"questions\":\(q)}}}\n",
       "golden: AskUserQuestion answered through PreToolUse")
    var askPR = ask
    askPR["hook_event_name"] = "PermissionRequest"
    eq(outText(hookOutput(event: "PermissionRequest", input: askPR, decision: HookDecision(.answer, answers: answers))) ?? "nil",
       "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"allow\",\"updatedInput\":{\"answers\":{\"Which extras?\":\"Tests, CI\",\"Which framework?\":\"React\"},\"questions\":\(q)}},\"hookEventName\":\"PermissionRequest\"}}\n",
       "golden: AskUserQuestion answered through PermissionRequest")
    // Never a decision by accident.
    check(hookOutput(event: "PermissionRequest", input: bash, decision: HookDecision(.terminal)) == nil, "terminal prints nothing")
    check(hookOutput(event: "PreToolUse", input: ask, decision: HookDecision(.terminal)) == nil, "question terminal prints nothing")
    check(hookOutput(event: "PreToolUse", input: ask, decision: HookDecision(.allow)) == nil, "bare allow on a question prints nothing")
    check(hookOutput(event: "PermissionRequest", input: askPR, decision: HookDecision(.allow)) == nil, "bare allow on a question permission prints nothing")
    check(hookOutput(event: "PreToolUse", input: ask, decision: HookDecision(.answer, answers: ["Which framework?": "React"])) == nil,
          "a missing answer prints nothing")
    check(hookOutput(event: "PreToolUse", input: ask, decision: HookDecision(.answer, answers: ["Which framework?": "React", "Which extras?": " "])) == nil,
          "a blank answer prints nothing")
    check(hookOutput(event: "PreToolUse", input: ask, decision: HookDecision(.answer, answers: answers.merging(["Bogus?": "x"]) { a, _ in a })) == nil,
          "an unknown question prints nothing")
    check(hookOutput(event: "PreToolUse", input: bash, decision: HookDecision(.allow)) == nil, "PreToolUse never allows a normal tool")
    check(hookOutput(event: "Stop", input: bash, decision: HookDecision(.allow)) == nil, "other events print nothing")
    check(hookOutput(event: "PermissionRequest", input: bash, decision: HookDecision(.answer, answers: answers)) == nil,
          "answers on a Bash permission print nothing")
    // Parsing the app's reply.
    eq(HookDecision.parse(jsonObj(#"{"decision":"allow"}"#)), HookDecision(.allow), "parse allow")
    check(HookDecision.parse(jsonObj(#"{"decision":"yes"}"#)) == nil, "unknown decision is no decision")
    check(HookDecision.parse(jsonObj(#"{"decision":"answer","answers":{"a":1}}"#)) == nil, "non-string answers rejected")
    check(HookDecision.parse(nil) == nil, "garbage reply is no decision")
    // Which hook calls wait.
    check(hookWantsDecision(event: "PermissionRequest", input: bash, terminal: true), "PermissionRequest waits (tab)")
    check(hookWantsDecision(event: "PermissionRequest", input: bash, terminal: false), "PermissionRequest waits (no terminal)")
    check(hookWantsDecision(event: "PreToolUse", input: ask, terminal: false), "no terminal: PreToolUse AskUserQuestion waits")
    check(!hookWantsDecision(event: "PreToolUse", input: ask, terminal: true),
          "tab: PreToolUse AskUserQuestion does not wait, so the terminal shows the question at once")
    check(!hookWantsDecision(event: "PreToolUse", input: jsonObj(#"{"tool_name":"Bash"}"#), terminal: false), "other PreToolUse is instant")
    // Which sessions have a terminal (env values seen from claude 2.1.322: tab, -p, --bg).
    check(hookHasTerminal(env: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "1"]), "interactive tab has a terminal")
    check(!hookHasTerminal(env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]), "claude -p has no terminal")
    check(!hookHasTerminal(env: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "0",
                                 "CLAUDE_JOB_DIR": "/Users/x/.claude/jobs/3f0a9b1c"]), "background agent has no terminal")
    check(!hookHasTerminal(env: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_JOB_DIR": "/j"]), "a job dir means background")
    check(!hookHasTerminal(env: [:]), "unknown env: no terminal")
    eq(HookArgs(["PermissionRequest", "--decide", "--timeout", "590"]), { var a = HookArgs([]); a.event = "PermissionRequest"; a.decide = true; a.timeout = 590; return a }(), "args parse")
    for bad in ["0", "-5", "nan", "inf", "x"] {
        eq(HookArgs(["PermissionRequest", "--decide", "--timeout", bad]).timeout, 0, "--timeout \(bad) is unusable")
    }
    eq(HookArgs(["PermissionRequest", "--decide", "--timeout", "99999"]).timeout, 3600, "--timeout is capped")
    check(runHook(argv: ["PermissionRequest", "--decide", "--timeout", "nan"], stdin: Data(bashInput.utf8), env: [:]) == nil,
          "an unusable --timeout never decides")
    let t0 = Date(timeIntervalSince1970: 1000)
    eq(hookDeadline(start: t0, timeout: 590), Date(timeIntervalSince1970: 1580), "deadline leaves a 10 s margin")
    eq(hookDeadline(start: t0, timeout: 2), Date(timeIntervalSince1970: 1001.6), "short timeouts keep 20%")
    // Helpers for the bubbles.
    eq(answerText(picked: ["Tests", "CI"], other: "", multiSelect: true), "Tests, CI", "multi-select joins with commas")
    eq(answerText(picked: ["Tests"], other: "Lint", multiSelect: true), "Tests, Lint", "multi-select Other is appended")
    eq(answerText(picked: ["React"], other: "Svelte", multiSelect: false), "Svelte", "single-select Other wins")
    eq(parseQuestions(ask["tool_input"] as! [String: Any]).map { $0.options.count }, [2, 3], "questions parsed")
    let pv = permissionPreview(toolName: "Bash", input: bash["tool_input"] as! [String: Any])
    eq(pv, PermissionPreview(title: "Bash", subtitle: "Write a file", body: "echo crewshelf-ok > /tmp/x.txt", style: .code), "bash preview")
    check(pv.warnings.isEmpty && !pv.tooLong, "plain bash: no warnings")
    let ed = permissionPreview(toolName: "Edit", input: ["file_path": NSHomeDirectory() + "/p/a.swift", "old_string": "let a = 1\nlet b = 2", "new_string": "let a = 3"])
    eq(ed.body, "- let a = 1\n- let b = 2\n+ let a = 3", "edit preview is a diff")
    eq(ed.subtitle ?? "", "~/p/a.swift", "edit preview path")
    eq(permissionPreview(toolName: "Write", input: ["file_path": "/x", "content": "a\nb\n"]).body, "+ a\n+ b", "write preview (no phantom last line)")
    let long = permissionPreview(toolName: "Bash", input: ["command": (0..<500).map(String.init).joined(separator: "\n")])
    check(long.body.hasSuffix("\n499") && long.lineCount == 500 && !long.tooLong, "500-line input is shown in full (it scrolls)")
    eq(permissionPreview(toolName: "mcp__gh__create_issue", input: ["title": "x"]).body, "{\n  \"title\" : \"x\"\n}", "unknown tool shows its JSON")
    // Event payloads are slimmed; decisions are not.
    let post = jsonObj(#"{"session_id":"s","tool_name":"Read","tool_input":{"file_path":"/a"},"tool_response":{"content":"huge"}}"#)
    check(slimEventInput(post)["tool_response"] == nil, "events drop tool_response")
    check(inputFingerprint(["a": 1, "b": "x"]) == inputFingerprint(["b": "x", "a": 1]), "fingerprint ignores key order")
    check(inputFingerprint(["a": 1]) != inputFingerprint(["a": 2]), "fingerprint follows content")
}

func centerTests() {
    let c = HookCenter()
    let t0 = Date()
    c.handleEvent("SessionStart", input: ["session_id": "s1", "cwd": "/tmp/proj", "source": "startup"], now: t0)
    c.handleEvent("UserPromptSubmit", input: ["session_id": "s1"], now: t0)
    let ti: [String: Any] = ["command": "ls", "description": "list"]
    c.handleEvent("PreToolUse", input: ["session_id": "s1", "tool_name": "Bash", "tool_use_id": "tu1", "tool_input": ti], now: t0)
    c.handleEvent("PreToolUse", input: ["session_id": "s1", "tool_name": "Bash", "tool_use_id": "tu2", "tool_input": ["command": "pwd"]], now: t0)
    eq(c.correlate(sessionId: "s1", toolName: "Bash", fingerprint: inputFingerprint(ti)) ?? "nil", "tu1",
       "PermissionRequest matched to its PreToolUse by session + tool + input")
    check(c.correlate(sessionId: "s1", toolName: "Bash", fingerprint: inputFingerprint(["command": "rm"])) == nil, "different input: no match")
    check(c.correlate(sessionId: "s2", toolName: "Bash", fingerprint: inputFingerprint(ti)) == nil, "different session: no match")
    c.handleEvent("PostToolUse", input: ["session_id": "s1", "tool_name": "Bash", "tool_use_id": "tu1", "tool_input": ti], now: t0)
    check(c.correlate(sessionId: "s1", toolName: "Bash", fingerprint: inputFingerprint(ti)) == nil, "finished step no longer matches")
    var h = c.snapshot().sessions.first { $0.sessionId == "s1" }!
    check(h.working, "PreToolUse means working")
    eq(h.steps.map { $0.step.pending }, [false, true], "PostToolUse finishes its step")
    c.handleEvent("Stop", input: ["session_id": "s1", "last_assistant_message": "All done: wrote 3 files."], now: t0.addingTimeInterval(5))
    h = c.snapshot().sessions.first { $0.sessionId == "s1" }!
    check(!h.working && h.doneAt != nil, "Stop means done")
    eq(h.lastMessage ?? "", "All done: wrote 3 files.", "done text from last_assistant_message")

    // Merge with the roster.
    var listed = Session(sessionId: "s1", name: "proj", cwd: "/tmp/proj", kind: .interactive, state: .idle)
    listed.pid = 1
    let other = Session(sessionId: "old", name: "old", cwd: "/x", kind: .background, state: .blocked)
    c.handleEvent("SessionStart", input: ["session_id": "hl", "cwd": "/tmp/headless"], now: t0)
    var merged = mergeHookSessions([listed, other], hooks: c.snapshot().sessions, pending: [])
    let m1 = merged.first { $0.sessionId == "s1" }!
    check(m1.hooked && m1.state == .idle && m1.doneKey != nil, "hooked session: idle after Stop with a Done key")
    eq(m1.doneText ?? "", "All done: wrote 3 files.", "merged done text")
    let mo = merged.first { $0.sessionId == "old" }!
    check(!mo.hooked && mo.state == .blocked, "no-plugin session keeps the polled state")
    let mh = merged.first { $0.sessionId == "hl" }!
    check(mh.headless && mh.name == "headless", "hook-only session is added")
    c.handleEvent("SessionEnd", input: ["session_id": "hl", "reason": "other"], now: t0)
    merged = mergeHookSessions([listed], hooks: c.snapshot().sessions, pending: [])
    check(merged.first { $0.sessionId == "hl" }?.isFinished == true, "SessionEnd: drawn as gone")
    c.prune(now: t0.addingTimeInterval(400))
    check(!c.snapshot().sessions.contains { $0.sessionId == "hl" }, "ended sessions are forgotten after 5 minutes")

    // Done: a check mark per Stop, never a bubble on its own.
    var q = BubbleQueue()
    q.update([m1]) { $0.doneText }
    check(q.open == nil && q.hasCheck("s1"), "Stop gives a check mark, no bubble")
    q.tap(m1)
    eq(q.open?.summary ?? "", "All done: wrote 3 files.", "clicking shows Done with the last message")

    // Unknown ids, ctl usage errors.
    if case .failure(let e) = c.decide("nope", HookDecision(.allow)) { eq(e, .unknown, "unknown request id") } else { check(false, "unknown id refused") }
    eq(c.control(["op": "decide", "id": "x", "decision": "answer"])["ok"] as? Bool, false, "ctl decide refuses answer")
    eq(c.control(["op": "bogus"])["ok"] as? Bool, false, "ctl unknown op")
}

/// A running server + center on a private socket. Returns the env the hook client needs.
func startServer(_ name: String, uid: uid_t = getuid()) -> (HookServer, HookCenter, [String: String]) {
    let dir = tmpBase + "hh-\(getpid())-\(name)"
    try? FileManager.default.removeItem(atPath: dir)
    let c = HookCenter()
    c.allowControlDecisions = true          // what CREWSHELF_TEST_CONTROL=1 does in the app
    let srv = HookServer(path: dir + "/crewshelf.sock")
    srv.allowedUid = uid
    srv.handler = { conn, obj in c.handle(conn, obj) }
    srv.onRelease = { conn, _ in c.released(conn.id) }
    do { try srv.start() } catch { check(false, "server start \(name): \(error)") }
    return (srv, c, ["CREWSHELF_SUPPORT_DIR": dir, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"])
}

/// Run the in-process hook client on a background thread.
func hookAsync(_ argv: [String], _ input: String, _ env: [String: String]) -> () -> (Data?, Double) {
    var result: Data?
    var secs = 0.0
    let done = DispatchSemaphore(value: 0)
    let t0 = Date()
    Thread {
        result = runHook(argv: argv, stdin: Data(input.utf8), env: env)
        secs = Date().timeIntervalSince(t0)
        done.signal()
    }.start()
    return { done.wait(); return (result, secs) }
}

func socketTests() {
    let (srv, c, env) = startServer("rt")
    defer { srv.stop() }
    let path = env["CREWSHELF_SUPPORT_DIR"]! + "/crewshelf.sock"
    var st = stat()
    stat(path, &st)
    eq(st.st_mode & 0o777, 0o600, "socket is mode 0600")
    stat(env["CREWSHELF_SUPPORT_DIR"]!, &st)
    eq(st.st_mode & 0o777, 0o700, "socket directory is 0700")

    // Event: fire and forget.
    let evInput = #"{"session_id":"rt-1","cwd":"/tmp/p","hook_event_name":"SessionStart","source":"startup"}"#
    let ev = runHook(argv: ["SessionStart"], stdin: Data(evInput.utf8), env: env)
    check(ev == nil, "event prints nothing")
    check(waitFor(2) { c.snapshot().sessions.contains { $0.sessionId == "rt-1" } }, "event reaches the app")

    // allow / deny / terminal through the in-process client.
    for (kind, want) in [(HookDecisionKind.allow, "\"behavior\":\"allow\""), (.deny, "\"behavior\":\"deny\""), (.terminal, "")] {
        let wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], bashInput, env)
        guard waitFor(3, { !c.snapshot().pending.isEmpty }) else { check(false, "request \(kind) pending"); _ = wait(); continue }
        let req = c.snapshot().pending[0]
        eq(req.kind, .permission, "request kind")
        eq(req.preview.body, "echo crewshelf-ok > /tmp/x.txt", "request shows the full command")
        check(req.deadline.timeIntervalSinceNow > 10, "deadline carried over the socket")
        if case .failure(let e) = c.decide(req.id, HookDecision(kind)) { check(false, "decide \(kind): \(e)") }
        let (out, _) = wait()
        if want.isEmpty { check(out == nil, "terminal: hook prints nothing") }
        else { check(outText(out)?.contains(want) == true, "round trip \(kind): \(outText(out) ?? "nil")") }
        check(waitFor(2) { c.snapshot().pending.isEmpty }, "request cleared after \(kind)")
    }

    // A question, answered through the --ctl path (same HookCenter.decide), with the real hook binary.
    let hookBin = FileManager.default.currentDirectoryPath + "/build/crewshelf-hook"
    var binOut = ""
    let qDone = DispatchSemaphore(value: 0)
    Thread {
        binOut = runTimed(hookBin, ["PreToolUse", "--decide", "--timeout", "30"], stdin: Data(askInput.utf8), env: env).1
        qDone.signal()
    }.start()
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "question pending")
    if let req = c.snapshot().pending.first {
        eq(req.kind, .question, "question kind")
        eq(req.questions.map { $0.question }, ["Which framework?", "Which extras?"], "every question is shown")
        if case .failure(let e) = c.decide(req.id, HookDecision(.allow)) { eq(e, .wrongKind, "allow on a question is refused") }
        if case .failure(let e) = c.decide(req.id, HookDecision(.answer, answers: ["Which framework?": "React"])) { eq(e, .badAnswers, "partial answers refused") }
        let ctlLine = canonicalJSON(["v": 1, "kind": "ctl", "op": "answer", "id": req.id,
                                     "answers": ["Which framework?": "Vue", "Which extras?": "Docs, CI"]])! + "\n"
        let reply = socketRequest(path: path, line: Data(ctlLine.utf8), connectBy: Date().addingTimeInterval(1),
                                  writeBy: Date().addingTimeInterval(2), replyBy: Date().addingTimeInterval(3))
        eq(jsonObj(outText(reply) ?? "")["ok"] as? Bool, true, "ctl answer accepted")
    }
    qDone.wait()
    let qo = jsonObj(binOut)["hookSpecificOutput"] as? [String: Any]
    eq(qo?["permissionDecision"] as? String, "allow", "binary: question allowed with answers")
    eq(((qo?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) ?? [:],
       ["Which framework?": "Vue", "Which extras?": "Docs, CI"], "binary: answers delivered")

    // ctl decide over the socket with the real binary (the path `Crewshelf --ctl decide` takes).
    var permOut = ""
    let pDone = DispatchSemaphore(value: 0)
    Thread {
        permOut = runTimed(hookBin, ["PermissionRequest", "--decide", "--timeout", "30"], stdin: Data(bashInput.utf8), env: env).1
        pDone.signal()
    }.start()
    check(waitFor(3) { !c.snapshot().pending.isEmpty }, "binary permission pending")
    let listLine = canonicalJSON(["v": 1, "kind": "ctl", "op": "list"])! + "\n"
    let listed = jsonObj(outText(socketRequest(path: path, line: Data(listLine.utf8), connectBy: Date().addingTimeInterval(1),
                                               writeBy: Date().addingTimeInterval(2), replyBy: Date().addingTimeInterval(3))) ?? "")
    let firstId = ((listed["pending"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
    check(!firstId.isEmpty, "ctl list shows the request")
    let decLine = canonicalJSON(["v": 1, "kind": "ctl", "op": "decide", "id": firstId, "decision": "allow"])! + "\n"
    _ = socketRequest(path: path, line: Data(decLine.utf8), connectBy: Date().addingTimeInterval(1),
                      writeBy: Date().addingTimeInterval(2), replyBy: Date().addingTimeInterval(3))
    pDone.wait()
    check(permOut.contains("\"behavior\":\"allow\""), "binary: ctl allow delivered")

    // Non-question PreToolUse with --decide returns at once; the "*" entry ignores AskUserQuestion.
    let t0 = Date()
    check(runHook(argv: ["PreToolUse", "--decide", "--timeout", "590"], stdin: Data(#"{"session_id":"rt-1","tool_name":"Bash","tool_use_id":"a","tool_input":{"command":"ls"}}"#.utf8), env: env) == nil, "normal PreToolUse prints nothing")
    check(Date().timeIntervalSince(t0) < 0.5, "normal PreToolUse returns at once")
    check(runHook(argv: ["PreToolUse"], stdin: Data(askInput.utf8), env: env) == nil, "plain PreToolUse on a question is silent")
    check(c.snapshot().pending.isEmpty, "…and opens no request")

    // Hook goes away mid-request (Claude killed it, or the prompt was answered in the terminal).
    if let fd = unixConnect(path, deadline: Date().addingTimeInterval(1)) {
        let line = hookRequestLine(event: "PermissionRequest", input: jsonObj(bashInput), decide: true, deadline: Date().addingTimeInterval(30))!
        _ = writeAll(fd, line, deadline: Date().addingTimeInterval(1))
        check(waitFor(2) { !c.snapshot().pending.isEmpty }, "raw request pending")
        let id = c.snapshot().pending.first?.id ?? ""
        close(fd)
        check(waitFor(2) { c.snapshot().pending.isEmpty }, "request dropped when the hook goes away")
        if case .failure(let e) = c.decide(id, HookDecision(.allow)) { eq(e, .unknown, "deciding a gone request fails") } else { check(false, "gone request refused") }
    }

    // Answered in the terminal: Claude Code moves on without stopping the hook. The call's own PostToolUse (or the
    // end of the batch or turn) releases the held request with no output.
    for (ev, extra) in [("PostToolUse", ["tool_use_id": "tu-x"]), ("PostToolBatch", [:]), ("Stop", ["last_assistant_message": "ok"]),
                        ("UserPromptSubmit", ["prompt": "next"])] as [(String, [String: String])] {
        let wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], bashInput, env)
        guard waitFor(3, { !c.snapshot().pending.isEmpty }) else { check(false, "\(ev): request pending"); _ = wait(); continue }
        if ev == "PostToolUse" {
            var other = jsonObj(bashInput)
            other["hook_event_name"] = "PostToolUse"; other["tool_input"] = ["command": "something else"]
            c.handleEvent("PostToolUse", input: other)
            check(c.snapshot().pending.count == 1, "a PostToolUse of a different call keeps the request")
        }
        var post = jsonObj(bashInput)
        post["hook_event_name"] = ev
        for (k, v) in extra { post[k] = v }
        let ev2 = runHook(argv: [ev], stdin: Data(canonicalJSON(post)!.utf8), env: env)
        check(ev2 == nil, "\(ev) event prints nothing")
        let (out, secs) = wait()
        check(out == nil, "answered elsewhere, then \(ev): the held hook prints nothing")
        check(secs < 5, "\(ev) released the hook at once")
        check(waitFor(2) { c.snapshot().pending.isEmpty }, "\(ev) cleared the bubble")
    }

    // Garbage and old-version lines are closed without effect.
    let junk = socketRequest(path: path, line: Data("not json\n".utf8), connectBy: Date().addingTimeInterval(1),
                             writeBy: Date().addingTimeInterval(2), replyBy: Date().addingTimeInterval(2))
    check(junk == nil, "garbage gets no reply")
    let past = canonicalJSON(["v": 1, "kind": "decide", "event": "PermissionRequest", "deadline": Date().timeIntervalSince1970 - 5,
                              "input": jsonObj(bashInput)])! + "\n"
    check(socketRequest(path: path, line: Data(past.utf8), connectBy: Date().addingTimeInterval(1), writeBy: Date().addingTimeInterval(2),
                        replyBy: Date().addingTimeInterval(2)) == nil, "a request already past its deadline is closed")
    check(c.snapshot().pending.isEmpty, "…and never pending")

    // A second server on the same path refuses to steal it.
    let second = HookServer(path: path)
    do { try second.start(); check(false, "second server must not start") } catch { check("\(error)".contains("otherServerRunning"), "second server refused: \(error)") }
}

/// Only the copy that owns the socket records itself in app-path: a second copy that quits must not point the
/// plugin's shim at itself (deleted later, it would make every hook a silent no-op).
func appPathClaimTests() {
    let dir = tmpBase + "hh-\(getpid())-claim"
    try? FileManager.default.removeItem(atPath: dir)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = dir + "/app-path"
    func recorded() -> String? { (try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .newlines) }
    let first = HookServer(path: dir + "/crewshelf.sock")
    eq(claimHookSocket(first, appPathFile: file, bundlePath: "/Applications/Crewshelf.app"), .owner, "the first copy owns the socket")
    eq(recorded(), "/Applications/Crewshelf.app", "…and records its path")
    let second = HookServer(path: dir + "/crewshelf.sock")
    eq(claimHookSocket(second, appPathFile: file, bundlePath: "/Users/demo/Downloads/Crewshelf.app"), .otherRunning,
       "a second copy finds the first on the socket")
    eq(recorded(), "/Applications/Crewshelf.app", "…and leaves app-path pointing at the running copy")
    first.stop()
    let third = HookServer(path: dir + "/crewshelf.sock")
    eq(claimHookSocket(third, appPathFile: file, bundlePath: "/Users/demo/Downloads/Crewshelf.app"), .owner,
       "once the first copy quit, the next one owns the socket")
    eq(recorded(), "/Users/demo/Downloads/Crewshelf.app", "…and records itself")
    third.stop()
    let demo = HookServer(path: dir + "/crewshelf.sock")
    eq(claimHookSocket(demo, appPathFile: nil, bundlePath: "/x/Crewshelf.app"), .owner, "a demo owns its own socket")
    eq(recorded(), "/Users/demo/Downloads/Crewshelf.app", "…and never writes app-path")
    demo.stop()
}

func deadlineTests() {
    let (srv, c, env) = startServer("dl")
    defer { srv.stop() }
    let wait = hookAsync(["PermissionRequest", "--decide", "--timeout", "1"], bashInput, env)   // gives up at 0.8 s
    check(waitFor(1) { !c.snapshot().pending.isEmpty }, "short request pending")
    let id = c.snapshot().pending.first?.id ?? ""
    let (out, secs) = wait()
    check(out == nil, "expired deadline: no output")
    check(secs < 1.0, "hook released itself before Claude's timeout (\(secs) s)")
    check(waitFor(1) { c.snapshot().pending.isEmpty }, "expired request dropped")
    if case .failure(let e) = c.decide(id, HookDecision(.allow)) { check(e == .unknown || e == .expired, "late allow refused") }
    else { check(false, "late allow must fail") }

    // The app's own deadline check: a decision after the deadline is never sent.
    let wait2 = hookAsync(["PermissionRequest", "--decide", "--timeout", "30"], bashInput, env)
    check(waitFor(2) { !c.snapshot().pending.isEmpty }, "second request pending")
    if let req = c.snapshot().pending.first {
        if case .failure(let e) = c.decide(req.id, HookDecision(.allow), now: req.deadline.addingTimeInterval(1)) {
            eq(e, .expired, "decide after the deadline: expired")
        } else { check(false, "decide after the deadline must fail") }
    }
    let (out2, _) = wait2()
    check(out2 == nil, "expired decision: the hook prints nothing")
}

func uidTests() {
    let (srv, c, env) = startServer("uid", uid: getuid() &+ 4242)
    defer { srv.stop() }
    let t0 = Date()
    let out = runHook(argv: ["PermissionRequest", "--decide", "--timeout", "30"], stdin: Data(bashInput.utf8), env: env)
    check(out == nil, "peer uid mismatch: no output")
    check(Date().timeIntervalSince(t0) < 0.5, "refused at once")
    check(waitFor(1) { srv.refused >= 1 }, "server counted the refusal")
    check(c.snapshot().pending.isEmpty && c.snapshot().sessions.isEmpty, "refused peer reached nothing")
}

func absentTests() {
    let cwd = FileManager.default.currentDirectoryPath
    let shim = cwd + "/plugin/bin/crewshelf-shim", hookBin = cwd + "/build/crewshelf-hook"
    let empty = tmpBase + "hh-\(getpid())-absent"
    try? FileManager.default.removeItem(atPath: empty)
    try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
    let env = ["CREWSHELF_SUPPORT_DIR": empty, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    let input = Data(bashInput.utf8)
    var worst = 0.0
    // Best of three runs per case: the bound is the program's own speed, not a load spike from other processes
    // (a busy machine adds tens of ms to any single spawn). Every run must still exit 0 with no output.
    func expectSilent(_ label: String, _ path: String, _ args: [String], _ e: [String: String], stdin: Data? = nil) {
        var best = Double.infinity
        for _ in 0..<3 {
            let (status, out, secs) = runTimed(path, args, stdin: stdin ?? input, env: e)
            eq(status, 0, "\(label): exit 0")
            eq(out, "", "\(label): no output")
            best = min(best, secs)
            worst = max(worst, secs)
        }
        check(best < 0.1, "\(label): under 100 ms (best of 3: \(Int(best * 1000)) ms)")
    }
    expectSilent("shim, never launched", shim, ["PermissionRequest", "--decide", "--timeout", "590"], env)
    try? "/nonexistent/Crewshelf.app\n".write(toFile: empty + "/app-path", atomically: false, encoding: .utf8)
    expectSilent("shim, app moved", shim, ["PermissionRequest", "--decide", "--timeout", "590"], env)
    let fake = empty + "/Fake.app/Contents/MacOS"
    try? FileManager.default.createDirectory(atPath: fake, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(atPath: hookBin, toPath: fake + "/crewshelf-hook")
    try? (empty + "/Fake.app\n").write(toFile: empty + "/app-path", atomically: false, encoding: .utf8)
    // macOS checks a freshly written binary on its first exec (one-time, ~150-250 ms). Measure warm runs, report cold.
    let cold = runTimed(fake + "/crewshelf-hook", ["PostToolUse"], stdin: input, env: env)
    print("app-absent fallback: first exec of a new binary copy \(Int(cold.2 * 1000)) ms (one-time OS check)")
    expectSilent("shim + hook, app not running", shim, ["PermissionRequest", "--decide", "--timeout", "590"], env)
    expectSilent("hook, no socket", hookBin, ["PermissionRequest", "--decide", "--timeout", "590"], env)
    expectSilent("hook, question, no socket", hookBin, ["PreToolUse", "--decide", "--timeout", "590"], env)
    expectSilent("hook, event, no socket", hookBin, ["PostToolUse"], env)
    // A stale socket file (app crashed) behaves the same.
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    if var a = makeAddr(empty + "/crewshelf.sock") {
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    close(stale)
    expectSilent("hook, stale socket file", hookBin, ["PermissionRequest", "--decide", "--timeout", "590"], env)
    expectSilent("hook, garbage stdin", hookBin, ["PermissionRequest", "--decide"], env, stdin: Data("{not json".utf8))
    print("app-absent fallback: slowest single warm run \(Int(worst * 1000)) ms")
}

func runHookTests() {
    goldenTests()
    centerTests()
    if sandboxed {
        print("SKIP socket round trip, deadline, peer uid and terminal-answer tests: this shell can't bind a Unix socket "
              + "in \(tmpBase) (a sandboxed shell or a restricted CI runner). Run ./build.sh in a normal shell for the "
              + "full suite, or set CREWSHELF_FORCE_SOCKET_TESTS=1 to make this a failure.")
    } else {
        socketTests()
        appPathClaimTests()
        deadlineTests()
        uidTests()
        resolveTests()
    }
    absentTests()
    previewAndArmTests()
    transcriptScanTests()
}
