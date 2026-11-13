import Foundation

// Plain test runner: swiftc-built, no XCTest needed. Exit code 1 on any failure.

var failures = 0
var passes = 0
func check(_ cond: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if cond { passes += 1 } else { failures += 1; print("FAIL \(what)  (line \(line))") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

/// Drop a test settings suite. removePersistentDomain alone leaves an empty plist behind (cfprefsd writes it a
/// moment later), so the files go at the end of the run, once cfprefsd has written them.
var droppedSuites: [String] = []
func dropSuite(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    droppedSuites.append(name)
}
/// cfprefsd sometimes writes the empty file only after this process exits, so each run also removes what earlier
/// runs left (suites named `...tests.[kind.]<pid>` whose process is gone).
func removeDroppedSuiteFiles() {
    let prefs = NSHomeDirectory() + "/Library/Preferences/"
    for n in droppedSuites { CFPreferencesAppSynchronize(n as CFString) }
    if !droppedSuites.isEmpty { usleep(500_000) }
    for n in droppedSuites { try? FileManager.default.removeItem(atPath: prefs + n + ".plist") }
    for f in (try? FileManager.default.contentsOfDirectory(atPath: prefs)) ?? [] where f.hasPrefix("io.github.aaliismail.crewshelf.tests.") {
        guard f.hasSuffix(".plist"), let pid = Int32(f.dropLast(6).split(separator: ".").last ?? ""),
              pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
        try? FileManager.default.removeItem(atPath: prefs + f)
    }
}

let fixtures = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures"
func fixture(_ name: String) -> String {
    (try? String(contentsOfFile: "\(fixtures)/\(name)", encoding: .utf8)) ?? ""
}

// MARK: slug rule (checked against real ~/.claude/projects directory names)
eq(projectSlug("/Users/demo"), "-Users-demo", "slug home")
eq(projectSlug("/Users/demo/billing-api"), "-Users-demo-billing-api", "slug dash kept")
eq(projectSlug("/Users/demo/.config/work-view"), "-Users-demo--config-work-view", "slug dot")
eq(projectSlug("/private/var/folders/ab/cd3ef_4gh5ij6kl0000gn/T"),
   "-private-var-folders-ab-cd3ef-4gh5ij6kl0000gn-T", "slug underscore")
eq(projectSlug("/Users/a/web-app/.claude/worktrees/fix-h53c"), "-Users-a-web-app--claude-worktrees-fix-h53c", "slug worktree")

// MARK: transcript parsing
let jsonl = """
{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-11-12T10:00:00.000Z"}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la\\ngit status","description":"list"}}]},"timestamp":"2026-11-12T10:00:01.000Z"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"timestamp":"2026-11-12T10:00:02.000Z"}
{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"side","name":"Read","input":{"file_path":"/x"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"\(NSHomeDirectory())/crewshelf/README.md"}}]},"timestamp":"2026-11-12T10:00:03.000Z"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"nope"}]}}
{"type":"api-request","params":{}}
not json at all
{"type":"assistant","message":{"content":[{"type":"text","text":"  Now editing.  "},{"type":"tool_use","id":"t3","name":"mcp__browser__click","input":{"element_index":3,"session":"s1"}}]},"timestamp":"2026-11-12T10:00:04.000Z"}
"""
let t = parseTranscript(jsonl, limit: 15)
eq(t.steps.count, 3, "steps count skips sidechain")
eq(t.steps.map { $0.name }, ["Bash", "Read", "browser.click"], "step names")
eq(t.steps[0].summary, "ls -la ⏎ git status", "bash summary flattens lines")
eq(t.steps[1].summary, "~/crewshelf/README.md", "read summary shortens home")
check(!t.steps[0].pending && !t.steps[0].isError, "t1 finished ok")
check(t.steps[1].isError, "t2 error flagged")
check(t.steps[2].pending, "t3 pending (no result yet)")
eq(t.lastText ?? "", "Now editing.", "last assistant text trimmed")
eq(parseTranscript(jsonl, limit: 2).steps.map { $0.id }, ["t2", "t3"], "limit keeps the most recent")
eq(summarizeTool(name: "Grep", input: ["pattern": "foo", "path": "/tmp"]), "foo  in /tmp", "grep summary")
eq(summarizeTool(name: "Agent", input: ["description": "Build it", "prompt": "long"]), "Build it", "agent summary")
eq(summarizeTool(name: "TodoWrite", input: ["todos": [1, 2, 3]]), "3 todos", "todo summary")
check(summarizeTool(name: "Bash", input: ["command": String(repeating: "x", count: 400)]).count <= 140, "summary capped")

// readTail drops the partial first line
let tmp = tmpBase + "crewshelf-tail-test.jsonl"
try? "first line is long\nsecond\nthird\n".write(toFile: tmp, atomically: false, encoding: .utf8)
eq(readTail(path: tmp, maxBytes: 13) ?? "", "third\n", "tail drops partial line")
eq(readTail(path: tmp, maxBytes: 1000) ?? "", "first line is long\nsecond\nthird\n", "tail whole file")

// MARK: state mapping and aggregation
eq(mapState(kind: .interactive, status: "waiting", jobState: nil), .blocked, "interactive waiting")
eq(mapState(kind: .interactive, status: "busy", jobState: nil), .working, "interactive busy")
eq(mapState(kind: .interactive, status: "shell", jobState: nil), .idle, "interactive shell = turn over")
eq(mapState(kind: .interactive, status: "idle", jobState: nil), .idle, "interactive idle")
eq(mapState(kind: .interactive, status: nil, jobState: nil), .idle, "interactive unknown")
eq(mapState(kind: .background, status: "idle", jobState: "blocked"), .blocked, "bg blocked")
eq(mapState(kind: .background, status: nil, jobState: "working"), .working, "bg working")
eq(mapState(kind: .background, status: "busy", jobState: "done"), .working, "bg busy process")
eq(mapState(kind: .background, status: nil, jobState: "done"), .idle, "bg done")

let rosterJSON = """
[{"id":"0a1b2c3d","cwd":"/Users/a","kind":"background","startedAt":1789411323987,"sessionId":"0a1b2c3d-1","name":"audit","state":"blocked"},
 {"pid":9030,"cwd":"/Users/a/billing-api","kind":"interactive","startedAt":1794266853167,"sessionId":"a1b2-1","name":"payments","status":"busy"},
 {"pid":9046,"cwd":"/Users/a","kind":"interactive","startedAt":1794266855652,"sessionId":"4d5e-1","name":"notes","status":"idle"},
 {"pid":81091,"id":"5e6f7a8b","cwd":"/Users/a","kind":"background","startedAt":1794439539263,"sessionId":"5e6f-1","name":"/review","status":"idle","state":"blocked"},
 {"kind":"interactive"}]
"""
let roster = parseRoster(Data(rosterJSON.utf8))
eq(roster.count, 4, "roster skips entries without sessionId")
eq(roster[0].shortId ?? "", "0a1b2c3d", "bg short id")
eq(roster[1].pid ?? 0, 9030, "interactive pid")

let sf = """
{"pid":9046,"sessionId":"4d5e-1","status":"waiting","waitingFor":"permission","statusUpdatedAt":1794496314312}
"""
let host = """
{"pid":13070,"sessionId":"7f8e","status":"idle","parkedJobId":"5e6f7a8b"}
"""
let files = [9046: parseSessionFile(Data(sf.utf8))!, 13070: parseSessionFile(Data(host.utf8))!]
let job = parseJobState(Data("""
{"state":"blocked","needs":"confirm: wire it?","suggestedReply":"yes","linkScanPath":"/tmp/x.jsonl","updatedAt":"2026-11-12T18:30:02.321Z"}
""".utf8))!
eq(job.needs ?? "", "confirm: wire it?", "job needs")
let timeline = """
{"at":"2026-11-12T17:00:00.000Z","state":"working"}
{"at":"2026-11-12T18:00:00.000Z","state":"blocked"}
{"at":"2026-11-12T18:30:00.000Z","state":"blocked"}
"""
eq(stateSince(timelineTail: timeline, state: "blocked"), isoDate("2026-11-12T18:00:00.000Z"), "state since = start of run")

let built = buildSessions(roster: roster, sessionFiles: files, jobs: ["5e6f7a8b": job],
                          jobSince: ["5e6f7a8b": isoDate("2026-11-12T18:00:00.000Z")!])
let notes = built.first { $0.name == "notes" }!
eq(notes.state, .blocked, "session file status overrides roster")
eq(notes.waitingFor ?? "", "permission", "waitingFor carried")
eq(notes.since, Date(timeIntervalSince1970: 1794496314.312), "since from statusUpdatedAt")
let reviewS = built.first { $0.shortId == "5e6f7a8b" }!
eq(reviewS.hostPid ?? 0, 13070, "bg agent attached tab found via parkedJobId")
eq(reviewS.needs ?? "", "confirm: wire it?", "bg needs")
eq(reviewS.transcriptPath ?? "", "/tmp/x.jsonl", "bg transcript path from job")
eq(built.first?.state, .blocked, "blocked sorted first")
eq(built.last?.state, .working, "working after blocked")
let counts = countStates(built)
eq(counts[.blocked] ?? 0, 3, "blocked count")
eq(counts[.working] ?? 0, 1, "working count")
eq(counts[.idle] ?? 0, 0, "idle count")

var hidden = HiddenStore()
hidden.hide(notes)
check(hidden.isHidden(notes), "hidden after Done")
eq(hidden.visible(built).count, 3, "hidden filtered out")
hidden.prune(built)
check(hidden.isHidden(notes), "still hidden while state unchanged")
var changed = notes
changed.state = .working
check(!hidden.isHidden(changed), "state change unhides")
check(hidden.prune([changed]), "prune drops changed entry")
eq(hidden.map.count, 0, "prune emptied")

// MARK: cmux mapping
let tree = fixture("cmux-tree.json")
let surfaces = parseCmuxTree(Data(tree.utf8))
eq(surfaces.count, 5, "surfaces flattened (incl. markdown)")
eq(surfaces.first?.tty ?? "", "ttys001", "tty read")
eq(surfaces.first?.workspaceRef ?? "", "workspace:1000070001", "workspace ref")
let ttys = parsePsTty(" 9046 ttys002\n13070 s003\n81091 ??\n")
eq(ttys, [9046: "ttys002", 13070: "ttys003"], "ps tty parse")
eq(surfaceFor(session: notes, ttyByPid: ttys, surfaces: surfaces)?.surfaceRef ?? "", "surface:1000070000", "interactive -> surface")
eq(surfaceFor(session: reviewS, ttyByPid: ttys, surfaces: surfaces)?.surfaceRef ?? "", "surface:1000070002", "bg -> attached surface")
var lone = reviewS
lone.hostPid = nil
check(surfaceFor(session: lone, ttyByPid: ttys, surfaces: surfaces) == nil, "unattached bg has no surface")
eq(Cmux.attachCommand(claude: "/opt/homebrew/bin/claude", id: "5e6f7a8b", cwd: "/Users/a"),
   ["new-surface", "--type", "terminal", "--focus", "true", "--command", "/opt/homebrew/bin/claude attach 5e6f7a8b",
    "--working-directory", "/Users/a"], "attach command")
let psAx = """
44811 ttys009  /opt/homebrew/bin/claude attach 9c8d7e6f
 9030 ttys001  /opt/homebrew/bin/claude --resume a1b2
  120 ??       /opt/homebrew/bin/claude attach deadbeef
  777 ttys004  vim attach notes.txt
"""
eq(parseAttachTtys(psAx), ["9c8d7e6f": "ttys009"], "attach tabs found by command line")
var attached = reviewS
attached.hostPid = nil
attached.shortId = "9c8d7e6f"
eq(surfaceFor(session: attached, ttyByPid: [:], attachTtys: ["9c8d7e6f": "ttys004"], surfaces: surfaces)?.surfaceRef ?? "",
   "surface:1000070006", "bg -> claude attach tab")
let s0 = surfaces[0]
eq(Cmux.focusCommands(s0).map { $0[0] }, ["focus-window", "select-workspace", "focus-panel"], "focus sequence")

// MARK: sprites, notifications, departures
eq(stableHash("abc"), 0xe71fa2190541574b, "FNV-1a is stable")
eq(spriteStyle(for: "1c2d3e4f-5a6b"), spriteStyle(for: "1c2d3e4f-5a6b"), "style stable per session")
let styles = Set((0..<40).map { spriteStyle(for: "session-\($0)").body.r })
check(styles.count >= 5, "sessions get varied colors")
func pix(_ l: Look, _ f: Int, _ v: Int = 0, fresh: Bool = false) -> Set<Pixel> { Set(spriteFrame(look: l, frame: f, variant: v, fresh: fresh)) }
check(pix(.working, 0) != pix(.working, 1), "working animates")
check(pix(.working, 1).contains { $0.kind == .spark }, "working throws sparks")
check(pix(.idle, 0) == pix(.idle, 1), "idle holds still")
eq(pix(.idle, 0).filter { $0.kind == .eye }.count, 2, "idle eyes half closed")
eq(pix(.working, 0).filter { $0.kind == .eye }.count, 4, "open eyes")
check(pix(.blocked, 1, fresh: true) != pix(.blocked, 1, fresh: false), "fresh block hops")
eq(pix(.blocked, 6, fresh: true), pix(.blocked, 6, fresh: false), "hop rests between jumps")
check(pix(.blocked, 0) != pix(.blocked, 2), "blocked waves")
check(pix(.idle, 0, 1).contains { $0.kind == .tip }, "antenna variant")
check(spriteFrame(look: .blocked, frame: 2, variant: 1, fresh: true).allSatisfy { $0.x >= 0 && $0.x < spriteGrid && $0.y >= 0 && $0.y < spriteGrid }, "hop stays in grid")
var fin = notes; fin.state = .idle; fin.rawState = "stopped"
eq(look(for: fin), .done, "stopped looks done")

var w = BlockWatcher()
eq(w.newlyBlocked(built).count, 0, "no alerts for prompts already open at launch")
eq(w.newlyBlocked(built).count, 0, "no repeat alerts")
var nb = built.first { $0.name == "payments" }!
nb.state = .blocked; nb.waitingFor = "permission prompt"; nb.since = Date(timeIntervalSince1970: 1_800_000_000)
eq(w.newlyBlocked(built + [nb]).map { $0.name }, ["payments"], "alert once for a new wait")
eq(w.newlyBlocked(built + [nb]).count, 0, "same wait not alerted twice")
nb.since = Date(timeIntervalSince1970: 1_800_000_100)
eq(w.newlyBlocked(built + [nb]).count, 1, "next prompt alerts again")

var dep = Departures()
let t0 = Date()
eq(dep.update(built, now: t0).count, 0, "nothing departed")
let fewer = Array(built.dropFirst())
let ghosts = dep.update(fewer, now: t0.addingTimeInterval(5))
eq(ghosts.map { $0.sessionId }, [built[0].sessionId], "departed agent kept")
check(ghosts.first?.isFinished == true, "departed agent drawn as done")
eq(dep.update(fewer, now: t0.addingTimeInterval(400)).count, 0, "ghost fades after 5 minutes")

// MARK: bubbles (one open at a time, oldest request first; Done never opens on its own; collapse)
func mk(_ id: String, _ st: HState, since: Double = 1_800_000_000, raw: String? = nil) -> Session {
    var s = Session(sessionId: id, name: id, cwd: "/p", kind: .interactive, state: st)
    s.since = Date(timeIntervalSince1970: since); s.rawState = raw; s.waitingFor = st == .blocked ? "permission" : nil
    return s
}
/// A hooked session with an open hook request created at `at`.
func req(_ id: String, _ reqId: String, at: Double) -> Session {
    var s = mk(id, .blocked, since: at)
    s.hooked = true; s.pendingKey = reqId
    return s
}
var q = BubbleQueue()
q.update([req("b", "r-b", at: 20), req("a", "r-a", at: 10), req("c", "r-c", at: 30), mk("w", .working)]) { _ in nil }
eq(q.visible.count, 1, "only one bubble open")
eq(q.open?.sessionId ?? "", "a", "the oldest request opens first")
eq(q.waiting([req("b", "r-b", at: 20), req("a", "r-a", at: 10), req("c", "r-c", at: 30)]).map { $0.sessionId }, ["b", "c"],
   "the others wait with a ! only")
var answeredA = mk("a", .working)
answeredA.hooked = true
q.update([req("b", "r-b", at: 20), answeredA, req("c", "r-c", at: 30)]) { _ in nil }
eq(q.open?.sessionId ?? "", "b", "answering the open request opens the next oldest")
q.dismiss(q.open!)
q.autoOpen([req("b", "r-b", at: 20), answeredA, req("c", "r-c", at: 30)])
eq(q.open?.sessionId ?? "", "c", "dismissing opens the next one at once")
q.update([req("b", "r-b", at: 20), answeredA, req("c", "r-c", at: 30)]) { _ in nil }
eq(q.open?.sessionId ?? "", "c", "a dismissed request does not come back on its own")
check(q.waiting([req("b", "r-b", at: 20), req("c", "r-c", at: 30)]).contains { $0.sessionId == "b" }, "a dismissed request keeps its !")
q.tap(req("b", "r-b", at: 20))
eq(q.open?.sessionId ?? "", "b", "clicking a waiting character opens its bubble and closes the other")
eq(q.visible.count, 1, "still one bubble")
q.dismiss(q.open!)
q.autoOpen([req("b", "r-b", at: 20), req("c", "r-c", at: 30)])
eq(q.open?.sessionId ?? "", "c", "the replaced request was not dismissed, so it comes back")
q.update([mk("b", .working), mk("c", .working)]) { _ in nil }
check(q.open == nil, "nothing open when nobody waits")
var q2 = BubbleQueue(dismissed: q.dismissed)
q2.update([req("b", "r-b", at: 20)]) { _ in nil }
check(q2.open == nil, "dismissals survive a restart")
q2.update([req("b", "r-b2", at: 40)]) { _ in nil }
eq(q2.open?.sessionId ?? "", "b", "a new request from the same agent opens")
var q2b = BubbleQueue()
q2b.update([mk("np", .blocked)]) { _ in nil }
check(q2b.open == nil, "a no-plugin wait never opens on its own (it shows !)")
q2b.tap(mk("np", .blocked))
eq(q2b.open?.kind, .prompt, "but a click opens it")

// Done: a check mark, never a bubble on its own.
var q3 = BubbleQueue()
let t9 = Date(timeIntervalSince1970: 1_900_000_000)
q3.update([mk("g", .working)], now: t9) { _ in nil }
q3.update([mk("g", .idle, since: 1_800_000_050)], now: t9) { _ in "wrote the plan" }
check(q3.open == nil, "a finished turn opens no bubble")
check(q3.hasCheck("g"), "it shows a check mark")
q3.update([mk("g", .idle, since: 1_800_000_050)], now: t9.addingTimeInterval(30)) { _ in nil }
check(q3.hasCheck("g"), "the check stays at 30 s")
q3.update([mk("g", .idle, since: 1_800_000_050)], now: t9.addingTimeInterval(61)) { _ in nil }
check(q3.hasCheck("g"), "…and after 60 s: it stays until clicked or working again")
var hk = mk("h", .idle)
hk.hooked = true; hk.doneKey = "h|stop|1"; hk.doneText = "All done."
var q4 = BubbleQueue()
q4.update([hk], now: t9) { $0.doneText }
check(q4.open == nil && q4.hasCheck("h"), "a Stop event gives a check mark, not a bubble")
q4.tap(hk)
eq(q4.open?.kind, .finished, "clicking the checked character shows Done")
eq(q4.open?.summary ?? "", "All done.", "Done shows the last message")
check(!q4.hasCheck("h"), "the click clears the check")
q4.dismiss(q4.open!)
q4.update([hk], now: t9.addingTimeInterval(5)) { $0.doneText }
check(!q4.hasCheck("h") && q4.open == nil, "the same Stop never marks twice")
hk.doneKey = "h|stop|2"
q4.update([hk], now: t9.addingTimeInterval(9)) { $0.doneText }
check(q4.hasCheck("h"), "the next Stop marks again")
q4.update([hk, req("x", "r-x", at: 5)], now: t9.addingTimeInterval(10)) { _ in nil }
eq(q4.open?.sessionId ?? "", "x", "requests still open while a check is showing")

// Collapse: nothing opens on its own; expanding opens the oldest request.
var q5 = BubbleQueue(collapsed: true)
q5.update([req("a", "r-a", at: 10), req("b", "r-b", at: 20)]) { _ in nil }
check(q5.open == nil, "collapsed: no bubble opens on its own")
eq(q5.needsYouCount([req("a", "r-a", at: 10), req("b", "r-b", at: 20), mk("w", .working)]), 2, "collapsed count of agents that need you")
q5.collapse(false, sessions: [req("a", "r-a", at: 10), req("b", "r-b", at: 20)])
eq(q5.open?.sessionId ?? "", "a", "expanding opens the oldest request")
q5.collapse(true, sessions: [])
check(q5.open == nil, "collapsing closes the open bubble")
let suite = "io.github.aaliismail.crewshelf.tests.\(getpid())"
if let d = UserDefaults(suiteName: suite) {
    ShelfPrefs(defaults: d).collapsed = true
    d.synchronize()
    check(ShelfPrefs(defaults: UserDefaults(suiteName: suite)!).collapsed, "collapsed setting reads back")
    if sandboxed { print("SKIP collapsed setting persists for a new process: `defaults` can't reach this suite from a sandboxed shell") }
    else {
    let other = run("/usr/bin/defaults", ["read", suite, ShelfPrefs.collapsedKey], timeout: 5)
    eq(other.out.trimmingCharacters(in: .whitespacesAndNewlines), "1", "collapsed setting persists for a new process")
    ShelfPrefs(defaults: d).collapsed = false
    d.synchronize()
    eq(run("/usr/bin/defaults", ["read", suite, ShelfPrefs.collapsedKey], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines),
       "0", "expanding persists too")
    }
    dropSuite(suite)
}

eq(formatDuration(42), "42s", "dur s")
eq(formatDuration(3 * 60 + 5), "3m", "dur m")
eq(formatDuration(5 * 3600), "5h", "dur h")
eq(formatDuration(3 * 86400), "3d", "dur d")

runCalmTests()
runP3Tests()
runHookTests()
runReviewTests()
removeDroppedSuiteFiles()
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
