import Foundation

// The wire between the plugin's hook client (`crewshelf-hook`) and the app, and the exact JSON the hook prints.
// Foundation only: this file is compiled into the hook binary on its own.
//
// Hook -> app, one line per connection:
//   {"v":1,"kind":"event","event":"PostToolUse","input":{...hook stdin...},"input_fp":"...","terminal":true}
//   {"v":1,"kind":"decide","event":"PermissionRequest","deadline":<epoch s>,"input":{...},"input_fp":"...","terminal":false}
// "terminal": the session has its own terminal prompt (an interactive tab), from the claude process env.
// "term" (optional): {"vars":{<allowlisted terminal env, see terminalEnvKeys>},"tty":"ttys003","pid":<claude pid>},
// so Open can find the session's tab in cmux, iTerm2, Terminal.app, Ghostty or tmux.
// App -> hook (decide only), one line, then the app closes:
//   {"decision":"allow"} | {"decision":"deny","message":"..."} | {"decision":"terminal"}
//   {"decision":"answer","answers":{"<question text>":"<label>"}}
// Anything else, or no reply, means no decision: the hook prints nothing.
//
// Control (`Crewshelf --ctl`), same socket. decide, answer and tap work only when the app was started with
// CREWSHELF_TEST_CONTROL=1 (tests); otherwise any process of this user could approve requests through it.
//   {"v":1,"kind":"ctl","op":"list"} | {"v":1,"kind":"ctl","op":"decide","id":"..","decision":"allow"}
//   {"v":1,"kind":"ctl","op":"answer","id":"..","answers":{...}}

public let hookWireVersion = 1
public let askToolName = "AskUserQuestion"

public enum HookDecisionKind: String {
    case allow, deny, terminal, answer
}

public struct HookDecision: Equatable {
    public var kind: HookDecisionKind
    public var message: String?
    public var answers: [String: String]?

    public init(_ kind: HookDecisionKind, message: String? = nil, answers: [String: String]? = nil) {
        self.kind = kind
        self.message = message
        self.answers = answers
    }

    public static let defaultDenyMessage = "The user denied this in Crewshelf."

    public var wire: [String: Any] {
        var d: [String: Any] = ["decision": kind.rawValue]
        if let m = message { d["message"] = m }
        if let a = answers { d["answers"] = a }
        return d
    }

    public static func parse(_ obj: Any?) -> HookDecision? {
        guard let d = obj as? [String: Any], let k = (d["decision"] as? String).flatMap(HookDecisionKind.init) else {
            return nil
        }
        var answers: [String: String]?
        if let a = d["answers"] {
            guard let m = a as? [String: String] else { return nil }
            answers = m
        }
        return HookDecision(k, message: d["message"] as? String, answers: answers)
    }
}

/// True when the Claude Code session that ran this hook has its own terminal prompt: an interactive `claude`
/// in a terminal. False for `claude -p` (entrypoint "sdk-cli"), SDK hosts and background agents (unattended, with a
/// job dir). Hooks inherit the claude process env. Unknown means false: the bubble then holds the question itself
/// and offers no "Answer in terminal", which can only cost convenience, never approve anything.
public func hookHasTerminal(env: [String: String]) -> Bool {
    env["CLAUDE_CODE_ENTRYPOINT"] == "cli" && env["CLAUDE_CODE_SESSION_ATTENDED"] != "0"
        && (env["CLAUDE_JOB_DIR"] ?? "").isEmpty
}

/// True for the hook calls that wait for the user: every PermissionRequest, and PreToolUse on AskUserQuestion when
/// the session has no terminal. With a terminal, a held PreToolUse would keep the question off the screen, so the
/// question is held at its PermissionRequest instead, which Claude Code runs alongside its own terminal dialog.
public func hookWantsDecision(event: String, input: [String: Any], terminal: Bool) -> Bool {
    switch event {
    case "PermissionRequest": return true
    case "PreToolUse": return !terminal && (input["tool_name"] as? String) == askToolName
    default: return false
    }
}

/// Stable JSON text (sorted keys) for golden tests and fingerprints.
public func canonicalJSON(_ obj: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(decoding: d, as: UTF8.self)
}

/// Fingerprint of a tool call's input. PreToolUse and PermissionRequest carry the same tool_input, but only
/// PreToolUse has a tool_use_id, so this is how a permission request is matched to the step it belongs to.
public func inputFingerprint(_ toolInput: Any?) -> String {
    let text = toolInput.flatMap { canonicalJSON($0) } ?? "null"
    var h: UInt64 = 0xcbf29ce484222325
    for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

/// Question texts of an AskUserQuestion input, in order.
public func questionTexts(_ toolInput: [String: Any]) -> [String] {
    ((toolInput["questions"] as? [[String: Any]]) ?? []).compactMap { $0["question"] as? String }
}

/// Answers are usable only if every question has a non-empty answer and no unknown question is answered.
public func answersValid(_ answers: [String: String], questions: [String]) -> Bool {
    guard !questions.isEmpty, Set(answers.keys) == Set(questions) else { return false }
    return answers.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The exact stdout a hook prints for a decision, or nil for "print nothing" (no decision).
/// `input` is the hook's own stdin JSON. Nothing here ever turns a missing or odd decision into an allow.
public func hookOutput(event: String, input: [String: Any], decision: HookDecision) -> Data? {
    let tool = input["tool_name"] as? String
    let toolInput = input["tool_input"] as? [String: Any]
    func emit(_ obj: [String: Any]) -> Data? { canonicalJSON(obj).map { Data(($0 + "\n").utf8) } }

    switch (event, decision.kind) {
    case (_, .terminal):
        return nil
    case ("PermissionRequest", .allow):
        guard tool != askToolName else { return nil }       // a question needs its answers, not a bare allow
        var dec: [String: Any] = ["behavior": "allow"]
        if let ti = toolInput { dec["updatedInput"] = ti }
        return emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": dec]])
    case ("PermissionRequest", .deny):
        let msg = decision.message.flatMap { $0.isEmpty ? nil : $0 } ?? HookDecision.defaultDenyMessage
        return emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                            "decision": ["behavior": "deny", "message": msg]]])
    case (_, .answer):
        guard tool == askToolName, var ti = toolInput, let answers = decision.answers,
              answersValid(answers, questions: questionTexts(ti)) else { return nil }
        ti["answers"] = answers
        if event == "PreToolUse" {
            return emit(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                "updatedInput": ti]])
        }
        if event == "PermissionRequest" {
            return emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                "decision": ["behavior": "allow", "updatedInput": ti]]])
        }
        return nil
    default:
        return nil
    }
}

/// What the hook sends for a fire-and-forget event: the input minus bulky fields the app never reads.
public func slimEventInput(_ input: [String: Any]) -> [String: Any] {
    var out = input
    out.removeValue(forKey: "tool_response")
    if let ti = input["tool_input"] as? [String: Any] {
        out["tool_input"] = ti.mapValues { v -> Any in
            if let s = v as? String, s.count > 2000 { return String(s.prefix(2000)) }
            if v is [Any] || v is [String: Any] {
                if let j = canonicalJSON(v), j.utf8.count > 4000 { return "(large)" }
            }
            return v
        }
    }
    if let m = input["last_assistant_message"] as? String, m.count > 4000 { out["last_assistant_message"] = String(m.prefix(4000)) }
    return out
}

/// The request line the hook sends. `terminal`: the session can show its own prompt (see hookHasTerminal).
/// `term`: which terminal the session runs in (allowlisted env, tty, claude pid), for Open.
public func hookRequestLine(event: String, input: [String: Any], decide: Bool, deadline: Date?,
                            terminal: Bool = false, term: TerminalEnv? = nil) -> Data? {
    var req: [String: Any] = ["v": hookWireVersion, "kind": decide ? "decide" : "event", "event": event,
                              "input": decide ? input : slimEventInput(input),
                              "input_fp": inputFingerprint(input["tool_input"]), "terminal": terminal]
    if let t = term, !t.isEmpty { req["term"] = t.wire }
    if decide, let d = deadline { req["deadline"] = d.timeIntervalSince1970 }
    return canonicalJSON(req).map { Data(($0 + "\n").utf8) }
}

/// Where the app keeps its socket and path file. CREWSHELF_SUPPORT_DIR overrides it (tests).
public func crewshelfSupportDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let d = env["CREWSHELF_SUPPORT_DIR"], !d.isEmpty { return d }
    return NSHomeDirectory() + "/Library/Application Support/Crewshelf"
}

public func crewshelfSocketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    crewshelfSupportDir(env: env) + "/crewshelf.sock"
}
