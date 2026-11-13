import Foundation

// `Crewshelf --demo`: five made-up agents that loop through working, a permission request, a question, done and
// idle, for screenshots and the README GIF. Everything is fed into a HookCenter as if from the plugin, so the
// shelf and bubbles behave exactly as they do for real, and the buttons answer the fake requests. Nothing here
// reads ~/.claude, runs claude, or touches the real socket (see demoEnvironment).

public enum DemoBeat {
    case wait(TimeInterval)
    case prompt
    case tool(String, [String: Any], TimeInterval)     // PreToolUse now, PostToolUse after the duration
    case permission(String, [String: Any])             // PreToolUse plus a held PermissionRequest
    case question([String: Any])                       // AskUserQuestion: PreToolUse plus a held PermissionRequest
    case stop(String)
}

public struct DemoAgent {
    public var id: String
    public var name: String
    public var cwd: String
    public var kind: SessionKind
    public var shortId: String?
    public var startDelay: TimeInterval
    public var script: [DemoBeat]
}

let demoHome = "/Users/demo/code"

public let demoAgents: [DemoAgent] = [
    DemoAgent(id: "c6ef3620-demo-420b-9d1a-rate-limit", name: "rate-limit", cwd: demoHome + "/api", kind: .interactive,
              shortId: nil, startDelay: 0.5, script: [
        .prompt,
        .tool("Read", ["file_path": demoHome + "/api/src/middleware/auth.ts"], 1.4),
        .tool("Grep", ["pattern": "rateLimit", "path": demoHome + "/api/src"], 1.0),
        .tool("Edit", ["file_path": demoHome + "/api/src/middleware/rateLimit.ts",
                       "old_string": "export const limits = {}",
                       "new_string": "export const limits = { perKey: 100, windowMs: 60_000 }"], 1.6),
        .permission("Bash", ["command": "npm test -- --run src/middleware", "description": "Run the middleware tests"]),
        .wait(1.2),
        .stop("Added a token-bucket limiter (100 requests a minute per key) to every /v1 route. 18 middleware tests pass."),
        .wait(18),
    ]),
    DemoAgent(id: "ec48c90d-demo-490b-9d1a-billing-ui", name: "billing-ui", cwd: demoHome + "/web", kind: .interactive,
              shortId: nil, startDelay: 1.5, script: [
        .prompt,
        .tool("Read", ["file_path": demoHome + "/web/app/settings/page.tsx"], 1.6),
        .tool("Glob", ["pattern": "app/settings/**/*.tsx"], 1.0),
        .question(["questions": [[
            "question": "Where should the billing settings live?", "header": "Layout", "multiSelect": false,
            "options": [["label": "Own tab", "description": "A Billing tab next to Profile and Team"],
                        ["label": "Inside Account", "description": "A section at the bottom of Account"],
                        ["label": "Modal", "description": "Opens from the plan badge in the header"]],
        ]]]),
        .tool("Write", ["file_path": demoHome + "/web/app/settings/billing/page.tsx", "content": "export default function Billing() {}"], 2.0),
        .tool("Edit", ["file_path": demoHome + "/web/app/settings/layout.tsx", "old_string": "tabs", "new_string": "tabs"], 1.4),
        .stop("Billing has its own Settings tab now: plan, invoices and the payment method."),
        .wait(20),
    ]),
    DemoAgent(id: "6884d953-demo-470b-9d1a-ios-crash", name: "ios-crash", cwd: demoHome + "/ios-app", kind: .background,
              shortId: "7c41e2a9", startDelay: 0.2, script: [
        .prompt,
        .tool("Read", ["file_path": demoHome + "/ios-app/Sources/App/KeychainStore.swift"], 1.5),
        .tool("Bash", ["command": "xcodebuild test -scheme App -only-testing:AppTests/KeychainTests",
                       "description": "Run the keychain tests"], 4.0),
        .tool("Edit", ["file_path": demoHome + "/ios-app/Sources/App/KeychainStore.swift",
                       "old_string": "try! read()", "new_string": "try read()"], 1.5),
        .tool("Bash", ["command": "xcodebuild test -scheme App -only-testing:AppTests/KeychainTests",
                       "description": "Run the keychain tests"], 3.5),
        .stop("Fixed the launch crash when the keychain is locked, and added a regression test."),
        .wait(25),
    ]),
    DemoAgent(id: "ec48c90d-demo-490b-9d1a-deploy-docs", name: "deploy-docs", cwd: demoHome + "/docs", kind: .interactive,
              shortId: nil, startDelay: 14, script: [
        .prompt,
        .tool("Read", ["file_path": demoHome + "/docs/guide/deploy.md"], 1.2),
        .permission("Edit", ["file_path": demoHome + "/docs/guide/deploy.md",
                             "old_string": "Set `DATABASE_URL` before you deploy.",
                             "new_string": "Set `DATABASE_URL` and `REDIS_URL` before you deploy.\nBoth are read at startup; a missing one stops the server."]),
        .stop("Updated the deploy guide for the new REDIS_URL variable."),
        .wait(30),
    ]),
    DemoAgent(id: "489e4ae1-demo-490b-9d1a-ingest-fix", name: "ingest-fix", cwd: demoHome + "/pipeline", kind: .interactive,
              shortId: nil, startDelay: 0, script: [
        .prompt,
        .tool("Bash", ["command": "pytest tests/test_ingest.py -q", "description": "Run the ingest tests"], 2.2),
        .stop("The nightly ingest is green again: the S3 prefix had a trailing slash."),
        .wait(45),
    ]),
]

/// Where a demo keeps its files, and the settings it uses: never the real support folder (the plugin's hooks look
/// for the app there) and never the real defaults. Returns the variables to set before anything reads them.
public let demoDefaultsSuite = "io.github.aaliismail.crewshelf.demo"

public func demoEnvironment(_ env: [String: String], tmp: String = NSTemporaryDirectory()) -> [String: String] {
    var out: [String: String] = [:]
    let real = crewshelfSupportDir(env: [:])
    let dir = env["CREWSHELF_SUPPORT_DIR"] ?? ""
    if dir.isEmpty || (dir as NSString).standardizingPath == (real as NSString).standardizingPath {
        out["CREWSHELF_SUPPORT_DIR"] = (tmp as NSString).appendingPathComponent("crewshelf-demo-\(getuid())")
    }
    let suite = env["CREWSHELF_DEFAULTS"] ?? ""
    if suite.isEmpty || suite == "io.github.aaliismail.crewshelf" { out["CREWSHELF_DEFAULTS"] = demoDefaultsSuite }
    out["CREWSHELF_NO_ROSTER"] = "1"
    out["CREWSHELF_QUIET"] = "1"
    return out
}

public final class DemoDriver {
    public let hooks: HookCenter
    public let agents: [DemoAgent]
    public var frozen = false
    /// A demo request nobody answers is let go after this long, as if answered in the terminal, so the loop goes on.
    public var answerTimeout: TimeInterval = 25
    public var restartAfter: TimeInterval = 12

    private struct Running {
        var beat = 0
        var nextAt: Date
        var cycle = 0
        var calls = 0
        var post: (id: String, tool: String, input: [String: Any], at: Date)?
        var waiting: (requestId: String, toolUseId: String, tool: String, input: [String: Any], since: Date)?
        var released: Date?               // let go to "the terminal": its PostToolUse comes 2 s later
        var endedAt: Date?
    }
    private var run: [Running]
    private let start: Date
    private let inboxLock = NSLock()
    private var inbox: [(agent: Int, requestId: String, decision: [String: Any]?)] = []

    public init(hooks: HookCenter, agents: [DemoAgent] = demoAgents, now: Date = Date()) {
        self.hooks = hooks
        self.agents = agents
        start = now
        run = agents.map { Running(nextAt: now.addingTimeInterval($0.startDelay)) }
        for i in agents.indices { send(i, "SessionStart", [:], now: now) }
    }

    /// The demo's `claude agents`: every agent that has not been ended, as an interactive tab or a background job.
    public func roster(now: Date = Date()) -> [Session] {
        agents.enumerated().compactMap { i, a in
            guard run[i].endedAt == nil else { return nil }
            var s = Session(sessionId: a.id, name: a.name, cwd: a.cwd, kind: a.kind, state: .idle)
            s.shortId = a.shortId
            s.startedAt = start.addingTimeInterval(Double(i))
            return s
        }
    }

    public func index(of sessionId: String) -> Int? { agents.firstIndex { $0.id == sessionId } }

    /// End (a background agent) or Hide (a tab): it leaves the shelf, and comes back `restartAfter` later.
    public func end(_ sessionId: String, now: Date = Date()) {
        guard let i = index(of: sessionId), run[i].endedAt == nil else { return }
        if let w = run[i].waiting { send(i, "PostToolUse", ["tool_name": w.tool, "tool_input": w.input, "tool_use_id": w.toolUseId], now: now) }
        send(i, "SessionEnd", [:], now: now)
        run[i] = Running(nextAt: now.addingTimeInterval(restartAfter), cycle: run[i].cycle + 1, calls: run[i].calls)
        run[i].endedAt = now
    }

    /// Advance every agent to `now`. Decisions made on the bubble (or through --ctl) are applied first.
    public func tick(now: Date = Date()) {
        inboxLock.lock()
        let decided = inbox
        inbox = []
        inboxLock.unlock()
        for d in decided { apply(d.agent, d.requestId, d.decision, now: now) }
        guard !frozen else { return }
        for i in agents.indices { advance(i, now: now) }
    }

    private func advance(_ i: Int, now: Date) {
        if let end = run[i].endedAt {
            guard now.timeIntervalSince(end) >= restartAfter else { return }
            run[i].endedAt = nil
            send(i, "SessionStart", [:], now: now)
        }
        if let p = run[i].post, now >= p.at {
            send(i, "PostToolUse", ["tool_name": p.tool, "tool_input": p.input, "tool_use_id": p.id], now: now)
            run[i].post = nil
        }
        if let w = run[i].waiting {
            if let r = run[i].released {
                guard now.timeIntervalSince(r) >= 2 else { return }
                finishCall(i, w.toolUseId, w.tool, w.input, failed: false, now: now)
            } else if now.timeIntervalSince(w.since) >= answerTimeout {
                run[i].released = now        // nobody answered: as if it was answered in the terminal
                return
            } else {
                return
            }
        }
        var guardSteps = 0
        while run[i].post == nil, run[i].waiting == nil, now >= run[i].nextAt, guardSteps < 20 {
            guardSteps += 1
            let script = agents[i].script
            if run[i].beat >= script.count { run[i].beat = 0; run[i].cycle += 1 }
            let beat = script[run[i].beat]
            run[i].beat += 1
            fire(i, beat, now: now)
        }
    }

    private func nextCallId(_ i: Int) -> String {
        run[i].calls += 1
        return "toolu_demo_\(agents[i].name)_\(run[i].calls)"
    }

    private func fire(_ i: Int, _ beat: DemoBeat, now: Date) {
        var delay: TimeInterval = 0.8
        switch beat {
        case .wait(let t):
            delay = t
        case .prompt:
            send(i, "UserPromptSubmit", ["prompt": "(demo)"], now: now)
        case .tool(let name, let input, let dur):
            let id = nextCallId(i)
            send(i, "PreToolUse", ["tool_name": name, "tool_input": input, "tool_use_id": id], now: now)
            run[i].post = (id, name, input, now.addingTimeInterval(dur))
            delay = dur + 0.4
        case .permission(let name, let input):
            hold(i, name, input, now: now)
        case .question(let input):
            hold(i, askToolName, input, now: now)
        case .stop(let message):
            send(i, "Stop", ["last_assistant_message": message, "stop_hook_active": false], now: now)
        }
        run[i].nextAt = now.addingTimeInterval(delay)
    }

    /// A PreToolUse and a held PermissionRequest, the way an interactive tab asks. The request's connection is
    /// in-process: whatever the user decides comes back through `inbox`.
    private func hold(_ i: Int, _ tool: String, _ input: [String: Any], now: Date) {
        let id = nextCallId(i)
        send(i, "PreToolUse", ["tool_name": tool, "tool_input": input, "tool_use_id": id], now: now)
        var reqId = ""
        let conn = HookConnection(local: { [weak self] decision in
            guard let self = self else { return }
            self.inboxLock.lock()
            self.inbox.append((i, reqId, decision))
            self.inboxLock.unlock()
        })
        reqId = conn.id
        let input = base(i).merging(["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input]) { _, b in b }
        guard hooks.addPending(conn: conn, event: "PermissionRequest", input: input, fingerprint: nil,
                               deadline: now.addingTimeInterval(590), terminal: true, term: nil, now: now) != nil else { return }
        run[i].waiting = (reqId, id, tool, input["tool_input"] as? [String: Any] ?? [:], now)
        run[i].released = nil
    }

    private func apply(_ i: Int, _ requestId: String, _ decision: [String: Any]?, now: Date) {
        guard let w = run[i].waiting, w.requestId == requestId else { return }
        switch HookDecision.parse(decision)?.kind {
        case .allow?, .answer?:
            finishCall(i, w.toolUseId, w.tool, w.input, failed: false, now: now)
        case .deny?:
            finishCall(i, w.toolUseId, w.tool, w.input, failed: true, now: now)
            // Claude stops after a denial: jump to the end of this turn.
            let script = agents[i].script
            if let stop = script.indices.first(where: { j in
                guard j >= run[i].beat, case .stop = script[j] else { return false }
                return true
            }) {
                run[i].beat = stop + 1
            }
            send(i, "Stop", ["last_assistant_message": "Okay, I won't run that. Tell me what you'd like instead."], now: now)
            run[i].nextAt = now.addingTimeInterval(1)
        case .terminal?, nil:
            run[i].released = now           // answered in the terminal: the call goes on a moment later
        }
    }

    private func finishCall(_ i: Int, _ id: String, _ tool: String, _ input: [String: Any], failed: Bool, now: Date) {
        send(i, failed ? "PostToolUseFailure" : "PostToolUse", ["tool_name": tool, "tool_input": input, "tool_use_id": id], now: now)
        run[i].waiting = nil
        run[i].released = nil
        run[i].nextAt = now.addingTimeInterval(0.8)
    }

    private func base(_ i: Int) -> [String: Any] {
        ["session_id": agents[i].id, "cwd": agents[i].cwd, "permission_mode": "default"]
    }

    private func send(_ i: Int, _ event: String, _ extra: [String: Any], now: Date) {
        let input = base(i).merging(extra) { _, b in b }.merging(["hook_event_name": event]) { _, b in b }
        hooks.handleEvent(event, input: input, fingerprint: nil, terminal: true, term: nil, now: now)
    }

    /// Requests the demo is holding right now (for tests).
    public var waitingRequests: [String] { run.compactMap { $0.waiting?.requestId } }
}
