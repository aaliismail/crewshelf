import Foundation

// Unix-domain socket helpers shared by the hook client and the app's server. Darwin calls only, every one with a
// deadline, so nothing here can block past the time it was given.

func makeAddr(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

func setNonBlocking(_ fd: Int32, _ on: Bool) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
}

func noSigPipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Milliseconds left until `deadline`, clamped to [0, Int32.max].
func msLeft(_ deadline: Date) -> Int32 {
    let ms = deadline.timeIntervalSinceNow * 1000
    return ms <= 0 ? 0 : Int32(min(ms, Double(Int32.max)))
}

/// Connect to a Unix socket, giving up at `deadline`. Returns a blocking fd, or nil.
public func unixConnect(_ path: String, deadline: Date) -> Int32? {
    guard var addr = makeAddr(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    noSigPipe(fd)
    setNonBlocking(fd, true)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, msLeft(deadline)) == 1 else { close(fd); return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { close(fd); return nil }
    }
    setNonBlocking(fd, false)
    return fd
}

/// Write everything or fail by `deadline`.
public func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
    var off = 0
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return data.isEmpty }
        while off < data.count {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, msLeft(deadline)) == 1, p.revents & Int16(POLLOUT) != 0 else { return false }
            let n = write(fd, base + off, data.count - off)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
            off += n
        }
        return true
    }
}

public enum LineRead: Equatable {
    case line(Data)
    case closed          // peer closed before a full line
    case timeout
    case tooLong
}

/// Read one "\n"-terminated line (newline dropped) by `deadline`.
public func readLine(_ fd: Int32, deadline: Date, maxBytes: Int) -> LineRead {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&p, 1, msLeft(deadline))
        if pr < 0 { if errno == EINTR { continue }; return .closed }
        if pr == 0 { return .timeout }
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .closed }
        if n == 0 { return .closed }
        if let nl = chunk[0..<n].firstIndex(of: 10) {
            buf.append(contentsOf: chunk[0..<nl])
            return buf.count > maxBytes ? .tooLong : .line(buf)
        }
        buf.append(contentsOf: chunk[0..<n])
        if buf.count > maxBytes { return .tooLong }
    }
}

/// True when the other end of a connected Unix socket runs as this user.
public func peerIsSelf(_ fd: Int32, uid: uid_t = getuid()) -> Bool {
    var peer: uid_t = 0, gid: gid_t = 0
    return getpeereid(fd, &peer, &gid) == 0 && peer == uid
}

/// One request, one optional reply line. Used by the hook (events and decisions) and by `Crewshelf --ctl`.
/// Returns nil on any failure: no socket, refused, timeout, closed without a reply.
public func socketRequest(path: String, line: Data, connectBy: Date, writeBy: Date, replyBy: Date?) -> Data? {
    guard let fd = unixConnect(path, deadline: connectBy) else { return nil }
    defer { close(fd) }
    guard peerIsSelf(fd) else { return nil }      // only a server running as this user may answer
    guard writeAll(fd, line, deadline: writeBy) else { return nil }
    guard let by = replyBy else { return Data() }
    if case .line(let d) = readLine(fd, deadline: by, maxBytes: 4 << 20) { return d }
    return nil
}
