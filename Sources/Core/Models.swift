import Foundation

public enum SessionKind: String {
    case interactive
    case background
}

/// The three states Crewshelf shows. Order matters: it is the sort order in the list.
public enum HState: String, CaseIterable {
    case blocked
    case working
    case idle

    var sortRank: Int {
        switch self {
        case .blocked: return 0
        case .working: return 1
        case .idle: return 2
        }
    }
}

public struct Session: Equatable {
    public var sessionId: String
    public var shortId: String?          // background agents only
    public var name: String
    public var cwd: String
    public var kind: SessionKind
    public var pid: Int?                 // interactive (and some background) sessions
    public var rawStatus: String?        // busy | idle | shell | waiting
    public var rawState: String?         // background job state: working | blocked | ...
    public var state: HState
    public var since: Date?
    public var startedAt: Date?          // stable order on the shelf
    public var waitingFor: String?       // interactive: what the open dialog waits for
    public var needs: String?            // background: verbatim "needs from you" text
    public var suggestedReply: String?
    public var detail: String?
    public var transcriptPath: String?
    public var hostPid: Int?             // pid of an interactive tab that has this background agent attached
    public var hooked = false            // the Crewshelf plugin reports this session (answerable from the bubble)
    public var headless = false          // known only from hooks (claude -p, or not in `claude agents`)
    public var pendingKey: String?       // oldest open hook request (permission or question)
    public var hookSteps: [Step] = []
    public var doneText: String?         // last_assistant_message of the latest Stop
    public var doneKey: String?          // identity of that Stop, so each finished turn opens one Done bubble
    public var terminal: TerminalEnv?    // where it runs, from the env its hooks reported (for Open)

    public init(sessionId: String, name: String, cwd: String, kind: SessionKind, state: HState) {
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.state = state
    }

    public var project: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    /// Finished or stopped background job still listed (drawn greyed out).
    public var isFinished: Bool { ["done", "stopped", "failed", "killed", "exited"].contains(rawState ?? "") }

    /// The handle the claude CLI accepts for this session.
    public var cliId: String { shortId ?? sessionId }
}

public struct Step: Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var timestamp: Date?
    public var isError: Bool
    public var pending: Bool
}

public struct TranscriptSummary: Equatable {
    public var steps: [Step]
    public var lastText: String?
    public var lastTextAt: Date?
}

public struct SurfaceRef: Equatable {
    public var windowRef: String
    public var workspaceRef: String
    public var paneRef: String
    public var surfaceRef: String
    public var title: String
    public var tty: String?
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
