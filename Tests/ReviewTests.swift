import Foundation

// Fixes from the pre-publication review (docs/REVIEW.md), one block per finding.

func runReviewTests() {
    longSubtitleTests()
    shortPathTests()
    nulTests()
    shimOwnerTests()
    peerTests()
    quoteTests()
    appArgsTests()
}

/// security 1: a path or URL longer than the bubble shows is cut there, and then Approve is off.
func longSubtitleTests() {
    let deep = "/Users/x/proj/node_modules/.cache/" + String(repeating: "a/", count: 150) + "../../../../.zshrc"
    let w = permissionPreview(toolName: "Write", input: ["file_path": deep, "content": "x"])
    check(w.tooLong, "long Write path: Approve is off")
    check(w.warnings.contains("Path too long to show in full: Approve is off"), "long Write path: the warning says why")
    check((w.subtitle ?? "").hasSuffix("…") && wrappedRows(w.subtitle ?? "") <= subtitleMaxRows,
          "long Write path: cut to the rows the bubble shows")
    for tool in ["Edit", "MultiEdit", "NotebookEdit"] {
        let key = tool == "NotebookEdit" ? "notebook_path" : "file_path"
        check(permissionPreview(toolName: tool, input: [key: deep]).tooLong, "long \(tool) path: Approve is off")
    }
    let fits = "/Users/x/proj/src/" + String(repeating: "b", count: 150) + ".swift"
    let e = permissionPreview(toolName: "Edit", input: ["file_path": fits, "old_string": "a", "new_string": "b"])
    check(!e.tooLong && e.subtitle == fits, "a path that fits is shown whole and can be approved")
    let padded = permissionPreview(toolName: "Write", input: ["file_path": "/tmp/a" + String(repeating: "\n", count: 10) + "b",
                                                              "content": "x"])
    check(padded.tooLong, "a path padded with newlines can't push its end out of sight")
    let url = permissionPreview(toolName: "WebFetch", input: ["url": "https://example.com/" + String(repeating: "q", count: 400),
                                                              "prompt": "p"])
    check(url.tooLong && url.warnings.contains("URL too long to show in full: Approve is off"), "long WebFetch URL: Approve is off")
    let desc = permissionPreview(toolName: "Bash", input: ["command": "ls", "description": String(repeating: "word ", count: 100)])
    check(!desc.tooLong && wrappedRows(desc.subtitle ?? "") <= subtitleMaxRows,
          "long Bash description: cut, still approvable (the command itself is shown whole)")
    eq(clipRows(String(repeating: "x", count: 100), rows: 2, columns: 10), String(repeating: "x", count: 19) + "…", "clipRows by length")
    eq(clipRows("a\nb\nc\nd", rows: 2, columns: 10), "a\nb…", "clipRows by lines")
    eq(wrappedRows("abc\n\n" + String(repeating: "y", count: 45), columns: 44), 4, "wrappedRows counts empty lines and wraps")
}

/// security 2: "~" only for the home folder itself or a path inside it.
func shortPathTests() {
    eq(shortPath("/home/alice/.ssh/authorized_keys", homeDir: "/home/al"), "/home/alice/.ssh/authorized_keys",
       "a neighbour's folder is not shortened to ~")
    eq(shortPath("/home/al/.ssh/k", homeDir: "/home/al"), "~/.ssh/k", "inside home: ~")
    eq(shortPath("/home/al", homeDir: "/home/al"), "~", "home itself: ~")
    eq(shortPath("/home/al/x", homeDir: "/home/al/"), "~/x", "home with a trailing slash")
    eq(shortPath("/etc/hosts", homeDir: "/"), "/etc/hosts", "home / shortens nothing")
}

/// security 3: a NUL in agent text never reaches Process.run (whose exception would kill the app).
func nulTests() {
    let r = run("/bin/echo", ["a\u{0}b"], timeout: 5)
    check(!r.ok && r.err.contains("NUL"), "an argument with a NUL is refused, not run")
    eq(bannerSafe("rm -rf x\u{0}\ny\r\u{1b}[31m\u{7f}"), "rm -rf x  y  [31m ", "banner text loses its control characters")
    let script = "display notification \"\(bannerSafe("a\u{0}b"))\""
    check(!script.contains("\u{0}"), "the osascript argument has no NUL")
    eq(run("/bin/echo", [bannerSafe("ok\u{0}")], timeout: 5).out, "ok \n", "a cleaned banner text runs")
}

/// security 4: the shim only runs a hook client that only you (or root) could have written.
func shimOwnerTests() {
    let shim = FileManager.default.currentDirectoryPath + "/plugin/bin/crewshelf-shim"
    let dir = tmpBase + "hh-\(getpid())-owner"
    try? FileManager.default.removeItem(atPath: dir)
    let macos = dir + "/X.app/Contents/MacOS"
    try? FileManager.default.createDirectory(atPath: macos, withIntermediateDirectories: true)
    let hook = macos + "/crewshelf-hook"
    try? "#!/bin/sh\necho RAN\n".write(toFile: hook, atomically: false, encoding: .utf8)
    chmod(hook, 0o755)
    try? (dir + "/X.app\n").write(toFile: dir + "/app-path", atomically: false, encoding: .utf8)
    chmod(dir + "/app-path", 0o644)
    let env = ["CREWSHELF_SUPPORT_DIR": dir, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    func shimOut() -> String { runTimed(shim, ["PostToolUse"], stdin: Data("{}".utf8), env: env).1 }
    eq(shimOut(), "RAN\n", "shim runs a hook client you own")
    for (path, mode, back, what) in [(dir + "/X.app/Contents", mode_t(0o775), mode_t(0o755), "a group-writable Contents folder"),
                                     (hook, 0o757, 0o755, "a world-writable hook binary"),
                                     (dir + "/X.app", 0o777, 0o755, "a world-writable bundle"),
                                     (dir + "/app-path", 0o666, 0o644, "a world-writable app-path")] {
        chmod(path, mode)
        eq(shimOut(), "", "shim refuses \(what)")
        chmod(path, back)
    }
    eq(shimOut(), "RAN\n", "shim runs it again once the modes are back")
    try? FileManager.default.removeItem(atPath: dir)
}

/// security 4 and 5: the hook only talks to a server running as you; the server serves a bounded number at once.
func peerTests() {
    var fds: [Int32] = [0, 0]
    if socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 {
        check(peerIsSelf(fds[0]), "peer of a socketpair is this user")
        check(!peerIsSelf(fds[0], uid: getuid() &+ 4242), "a different uid is not accepted as the server")
        close(fds[0]); close(fds[1])
    } else { check(false, "socketpair") }

    if sandboxed { print("SKIP connection cap: this shell can't bind a Unix socket in \(tmpBase)"); return }
    let dir = tmpBase + "hh-\(getpid())-cap"
    try? FileManager.default.removeItem(atPath: dir)
    let srv = HookServer(path: dir + "/crewshelf.sock")
    srv.maxConnections = 2
    srv.handler = { _, _ in .hold(until: Date().addingTimeInterval(5)) }
    do { try srv.start() } catch { check(false, "cap server start: \(error)"); return }
    defer { srv.stop(); try? FileManager.default.removeItem(atPath: dir) }
    func open() -> Int32? {
        guard let fd = unixConnect(srv.path, deadline: Date().addingTimeInterval(1)) else { return nil }
        _ = writeAll(fd, Data("{\"v\":1}\n".utf8), deadline: Date().addingTimeInterval(1))
        return fd
    }
    let held = [open(), open()].compactMap { $0 }
    eq(held.count, 2, "two held connections")
    usleep(200_000)
    let before = srv.refused
    if let third = open() {
        eq(readLine(third, deadline: Date().addingTimeInterval(2), maxBytes: 1024), .closed, "over the cap: closed at once, no reply")
        close(third)
    }
    check(waitFor(1) { srv.refused == before + 1 }, "over the cap: counted as refused")
    held.forEach { close($0) }
    usleep(600_000)                 // the server notices the two are gone (it polls every 250 ms)
    if let again = open() {
        usleep(200_000)
        eq(srv.refused, before + 1, "under the cap again: served")
        close(again)
    }
}

/// security 6: words in the cmux attach command line are quoted when they need it.
func quoteTests() {
    eq(shellQuote("/opt/homebrew/bin/claude"), "/opt/homebrew/bin/claude", "safe word as is")
    eq(shellQuote("/Users/a b/.local/bin/claude"), "'/Users/a b/.local/bin/claude'", "space: quoted")
    eq(shellQuote("it's"), "'it'\\''s'", "single quote inside")
    eq(shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'", "command substitution stays text")
    eq(shellQuote(""), "''", "empty word")
    eq(Cmux.attachCommand(claude: "/Users/a b/.local/bin/claude", id: "5e6f7a8b", cwd: "")[6],
       "'/Users/a b/.local/bin/claude' attach 5e6f7a8b", "attach command with a space in the claude path")
}

/// stranger 2: --help prints usage and an unknown option starts nothing.
func appArgsTests() {
    eq(parseAppArgs([]), .run, "no arguments: start")
    eq(parseAppArgs(["--help"]), .help, "--help")
    eq(parseAppArgs(["-h"]), .help, "-h")
    eq(parseAppArgs(["--bogus"]), .bad("--bogus"), "unknown option")
    eq(parseAppArgs(["--select", "x"]), .bad("--select"), "the old debug --select is gone")
    eq(parseAppArgs(["--demo"]), .run, "--demo")
    eq(parseAppArgs(["--demo", "--ctl", "list"]), .run, "--demo --ctl")
    eq(parseAppArgs(["--ctl", "--anything"]), .run, "everything after --ctl is --ctl's")
    eq(parseAppArgs(["--dump", "--steps", "5"]), .run, "--dump --steps N")
    eq(parseAppArgs(["--jump", "--odd-name"]), .run, "a value that looks like an option")
    eq(parseAppArgs(["-NSDocumentRevisionsDebugMode", "YES"]), .run, "AppKit's own -NS arguments are left alone")
    check(appUsage.contains("--dump") && appUsage.contains("real session names"), "usage warns what --dump prints")
}
