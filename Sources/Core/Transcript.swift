import Foundation

/// Claude Code stores transcripts in ~/.claude/projects/<slug>/<sessionId>.jsonl where the slug is the
/// cwd with every character that is not an ASCII letter or digit replaced by "-".
/// e.g. /Users/demo/.config/work-view -> -Users-demo--config-work-view
public func projectSlug(_ cwd: String) -> String {
    String(cwd.map { c in (c.isASCII && (c.isLetter || c.isNumber)) ? c : "-" })
}

public func transcriptCandidates(projectsDir: String, cwd: String, sessionId: String) -> String {
    "\(projectsDir)/\(projectSlug(cwd))/\(sessionId).jsonl"
}

/// Locate a transcript: the job's recorded path, then the slug rule, then a scan of every project dir
/// (covers long paths that Claude Code shortens).
public func findTranscript(projectsDir: String, session: Session, fm: FileManager = .default) -> String? {
    if let p = session.transcriptPath, fm.fileExists(atPath: p) { return p }
    let direct = transcriptCandidates(projectsDir: projectsDir, cwd: session.cwd, sessionId: session.sessionId)
    if fm.fileExists(atPath: direct) { return direct }
    guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
    for d in dirs {
        let p = "\(projectsDir)/\(d)/\(session.sessionId).jsonl"
        if fm.fileExists(atPath: p) { return p }
    }
    return nil
}

/// Read the last `maxBytes` of a file, dropping the first (partial) line when not at file start.
public func readTail(path: String, maxBytes: Int) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? h.seek(toOffset: start)
    guard let data = try? h.readToEnd() else { return nil }
    var text = String(decoding: data, as: UTF8.self)
    if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
    return text
}

public let home = NSHomeDirectory()

/// `~` for the home folder itself or a path inside it. Only at a `/`: with home /home/al, /home/alice stays as is.
func shortPath(_ p: String, homeDir: String = home) -> String {
    let h = homeDir.hasSuffix("/") ? String(homeDir.dropLast()) : homeDir
    guard !h.isEmpty else { return p }
    if p == h { return "~" }
    return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
}

func oneLine(_ s: String, max: Int = 140) -> String {
    let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

/// A short, human summary of a tool call's input.
public func summarizeTool(name: String, input: [String: Any]) -> String {
    func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    switch name {
    case "Bash", "BashOutput", "PowerShell":
        return oneLine(str("command") ?? str("description") ?? "")
    case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
        return shortPath(str("file_path") ?? str("notebook_path") ?? "")
    case "Grep":
        let p = str("pattern") ?? ""
        return oneLine(str("path").map { "\(p)  in \(shortPath($0))" } ?? p)
    case "Glob":
        return oneLine(str("pattern") ?? "")
    case "WebFetch":
        return oneLine(str("url") ?? "")
    case "WebSearch":
        return oneLine(str("query") ?? "")
    case "Agent", "Task":
        return oneLine(str("description") ?? str("prompt") ?? "")
    case "Skill":
        return oneLine([str("skill"), str("args")].compactMap { $0 }.joined(separator: " "))
    case "TodoWrite":
        return "\((input["todos"] as? [Any])?.count ?? 0) todos"
    case "ToolSearch":
        return oneLine(str("query") ?? "")
    default:
        for k in ["command", "file_path", "path", "url", "query", "description", "prompt", "name"] {
            if let v = str(k) { return oneLine(k.hasSuffix("path") ? shortPath(v) : v) }
        }
        let firstString = input.keys.sorted().compactMap { input[$0] as? String }.first ?? ""
        return oneLine(firstString)
    }
}

/// Display name: mcp__server__tool -> server.tool
public func displayToolName(_ name: String) -> String {
    guard name.hasPrefix("mcp__") else { return name }
    let parts = name.dropFirst(5).components(separatedBy: "__")
    return parts.joined(separator: ".")
}

/// Turn the tail of a transcript JSONL into the last `limit` tool calls and the last assistant text.
/// Only main-thread entries count (sidechains are subagents).
public func parseTranscript(_ text: String, limit: Int = 15) -> TranscriptSummary {
    var steps: [Step] = []
    var index: [String: Int] = [:]
    var lastText: String?
    var lastTextAt: Date?
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard line.first == "{",
              let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        let type = d["type"] as? String
        guard type == "assistant" || type == "user" else { continue }
        if (d["isSidechain"] as? Bool) == true { continue }
        guard let msg = d["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { continue }
        let ts = isoDate(d["timestamp"])
        for item in content {
            switch (type, item["type"] as? String) {
            case ("assistant", "tool_use"):
                let id = item["id"] as? String ?? UUID().uuidString
                let name = item["name"] as? String ?? "?"
                let input = item["input"] as? [String: Any] ?? [:]
                index[id] = steps.count
                steps.append(Step(id: id, name: displayToolName(name), summary: summarizeTool(name: name, input: input),
                                  timestamp: ts, isError: false, pending: true))
            case ("assistant", "text"):
                if let t = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    lastText = t
                    lastTextAt = ts
                }
            case ("user", "tool_result"):
                if let id = item["tool_use_id"] as? String, let i = index[id] {
                    steps[i].pending = false
                    steps[i].isError = (item["is_error"] as? Bool) == true
                }
            default:
                break
            }
        }
    }
    return TranscriptSummary(steps: Array(steps.suffix(limit)), lastText: lastText, lastTextAt: lastTextAt)
}

/// Read and parse a transcript, widening the tail window when the first window holds no tool calls.
public func loadTranscript(path: String, limit: Int = 15) -> TranscriptSummary? {
    var best: TranscriptSummary?
    for bytes in [1_500_000, 8_000_000] {
        guard let tail = readTail(path: path, maxBytes: bytes) else { return best }
        let s = parseTranscript(tail, limit: limit)
        best = s
        if s.steps.count >= limit || tail.utf8.count < bytes - 1 { break }
    }
    return best
}
