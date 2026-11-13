import Foundation

public struct RunResult {
    public var status: Int32
    public var out: String
    public var err: String
    public var ok: Bool { status == 0 }
}

/// Run a program with a timeout. Output is drained concurrently so large output cannot deadlock.
/// An argument with a NUL in it is refused: Process.run raises an Objective-C exception for one, which no Swift code
/// can catch, so agent text with a NUL (a banner's summary, say) would otherwise kill the app.
public func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> RunResult {
    if path.contains("\0") || args.contains(where: { $0.contains("\0") }) {
        return RunResult(status: -1, out: "", err: "refused: an argument contains a NUL character")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["CMUX_QUIET"] = "1"
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return RunResult(status: -1, out: "", err: "\(error)") }

    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    p.waitUntilExit()
    timer.cancel()
    group.wait()
    return RunResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                     err: String(decoding: errData, as: UTF8.self))
}

public func firstExisting(_ paths: [String]) -> String? {
    paths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// One word for a shell command line: as is when it is only safe characters, else in single quotes.
public func shellQuote(_ s: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@%+=,")
    if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
