import Foundation

/// Parsed `crewshelf-hook <Event> [--decide] [--timeout <seconds>]`.
public struct HookArgs: Equatable {
    public var event: String?
    public var decide = false
    public var timeout: Double = 600

    public init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--decide" { decide = true }
            else if a == "--timeout", i + 1 < argv.count {
                if let v = Double(argv[i + 1]), v.isFinite, v > 0 { timeout = min(v, 3600) } else { timeout = 0 }
                i += 1
            }
            else if !a.hasPrefix("-") && event == nil { event = a }
            i += 1
        }
    }
}

/// When the hook gives up waiting: a little before Claude Code's own timeout kills it, so it always
/// exits cleanly with no output instead of being killed.
public func hookDeadline(start: Date, timeout: Double) -> Date {
    let t = max(0.2, timeout)
    let margin = t >= 60 ? 10 : t * 0.2
    return start.addingTimeInterval(t - margin)
}

/// Everything `crewshelf-hook` does, minus reading stdin and printing. Returns the bytes to print, or nil for
/// "print nothing". Every failure path returns nil: no app, no socket, refused, timeout, garbage reply.
public func runHook(argv: [String], stdin: Data, env: [String: String], start: Date = Date(),
                    parents: () -> [ProcEntry] = { ancestry(Int(getppid())) }) -> Data? {
    let args = HookArgs(argv)
    guard let input = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] else { return nil }
    guard let event = args.event ?? (input["hook_event_name"] as? String) else { return nil }
    let path = crewshelfSocketPath(env: env)
    let tool = input["tool_name"] as? String

    // The PreToolUse "*" entry stays silent on AskUserQuestion: the dedicated --decide entry owns that call.
    if event == "PreToolUse" && tool == askToolName && !args.decide { return nil }

    let terminal = hookHasTerminal(env: env)
    let term = captureTerminal(env: env, parents: parents())
    let decide = args.decide && hookWantsDecision(event: event, input: input, terminal: terminal)
    let connectBy = start.addingTimeInterval(0.25)
    if !decide {
        if let line = hookRequestLine(event: event, input: input, decide: false, deadline: nil, terminal: terminal, term: term) {
            _ = socketRequest(path: path, line: line, connectBy: connectBy, writeBy: start.addingTimeInterval(0.6),
                              replyBy: nil)
        }
        return nil
    }

    guard args.timeout > 0 else { return nil }      // an unusable --timeout never waits, never decides
    let deadline = hookDeadline(start: start, timeout: args.timeout)
    guard deadline > Date(),
          let line = hookRequestLine(event: event, input: input, decide: true, deadline: deadline, terminal: terminal, term: term),
          let reply = socketRequest(path: path, line: line, connectBy: connectBy,
                                    writeBy: start.addingTimeInterval(2), replyBy: deadline),
          Date() < deadline,
          let decision = HookDecision.parse(try? JSONSerialization.jsonObject(with: reply))
    else { return nil }
    return hookOutput(event: event, input: input, decision: decision)
}
