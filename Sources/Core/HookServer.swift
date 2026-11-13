import Foundation

/// One accepted hook connection. A decision request stays open until `respond` (the user decided),
/// `release` (no decision), the hook goes away, or its deadline passes.
public final class HookConnection {
    public let id: String
    let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private let sink: (([String: Any]?) -> Void)?

    init(fd: Int32) {
        self.fd = fd
        sink = nil
        id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    /// An in-process request with no socket (demo mode): the reply, or nil for a release, goes to `sink`. The sink
    /// is called with the connection's lock held, so it must only hand the value on.
    public init(local sink: @escaping ([String: Any]?) -> Void) {
        fd = -1
        self.sink = sink
        id = "demo" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Send one reply line and close. False if the connection was already closed (the hook is gone or timed out).
    @discardableResult
    public func respond(_ obj: [String: Any]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let text = canonicalJSON(obj) else { return false }
        if let s = sink { closed = true; s(obj); return true }
        let ok = writeAll(fd, Data((text + "\n").utf8), deadline: Date().addingTimeInterval(2))
        closed = true
        shutdown(fd, SHUT_RDWR)
        return ok
    }

    /// Close with no reply: the hook prints nothing.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if let s = sink { s(nil); return }
        shutdown(fd, SHUT_RDWR)
    }

    /// Only the serving thread closes the descriptor, once, so it is never reused while still polled.
    func finish() {
        release()
        Darwin.close(fd)
    }

    /// True once the hook end has closed (Claude killed it, or the user answered in the terminal). Bytes a client
    /// sends after its request line are read and dropped, so they can't keep poll() returning at once (a busy
    /// loop); more than 64 KB of them counts as a broken client and ends the request.
    private var junk = 0
    func peerGone(waitMs: Int32) -> Bool {
        lock.lock()
        if closed { lock.unlock(); return true }
        lock.unlock()
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, waitMs) == 1 else { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        lock.lock()
        defer { lock.unlock() }
        if closed { return true }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, Int32(MSG_DONTWAIT))
        if n == 0 { return true }
        if n < 0 { return errno != EAGAIN && errno != EINTR }
        junk += n
        return junk > 64 << 10
    }
}

public enum SocketClaim: Equatable { case owner, otherRunning, failed(String) }

/// Bind the app's hook socket, and only once this copy owns it, record `bundlePath` in `appPathFile` (the file the
/// plugin's shim reads to find `crewshelf-hook`). A second copy finds another Crewshelf on the socket and must leave
/// that file alone: it quits, and a path to it (deleted later, say) would turn every hook into a silent no-op.
public func claimHookSocket(_ srv: HookServer, appPathFile: String?, bundlePath: String) -> SocketClaim {
    do {
        try srv.start()
    } catch HookServer.StartError.otherServerRunning {
        return .otherRunning
    } catch {
        return .failed("\(error)")
    }
    if let file = appPathFile {
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? (bundlePath + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
    return .owner
}

/// What the request handler wants done with a connection after it returns.
public enum HookHold {
    case close                         // done (the handler may have replied)
    case hold(until: Date)             // keep open for a decision until this time
}

public enum HookReleaseReason: String { case decided, peerGone, deadline }

/// The app's socket server. Owner-only: the socket file is 0600 in a 0700 directory, and every peer's uid is
/// checked with getpeereid before a byte is read.
public final class HookServer {
    public let path: String
    public var allowedUid: uid_t = getuid()
    /// Connections served at once. More are closed unread (that hook prints nothing): a runaway or hostile process
    /// of this user can't pile up threads and buffers until the app falls over.
    public var maxConnections = 64
    private var live = 0
    public var handler: (HookConnection, [String: Any]) -> HookHold = { _, _ in .close }
    public var onRelease: (HookConnection, HookReleaseReason) -> Void = { _, _ in }
    public private(set) var refused = 0          // wrong uid, or over maxConnections
    private var listenFd: Int32 = -1
    private let lock = NSLock()

    public init(path: String) { self.path = path }

    public enum StartError: Error { case pathTooLong, otherServerRunning, socket(String) }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        guard var addr = makeAddr(path) else { throw StartError.pathTooLong }
        if FileManager.default.fileExists(atPath: path) {
            if let fd = unixConnect(path, deadline: Date().addingTimeInterval(0.3)) {
                close(fd)
                throw StartError.otherServerRunning
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket("socket: \(errno)") }
        let old = umask(0o177)
        let b = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard b == 0 else { close(fd); throw StartError.socket("bind: \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { close(fd); throw StartError.socket("listen: \(errno)") }
        listenFd = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "crewshelf.accept"
        t.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFd
        listenFd = -1
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func acceptLoop(_ lfd: Int32) {
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return          // closed by stop()
            }
            noSigPipe(c)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == allowedUid else {
                lock.lock(); refused += 1; lock.unlock()
                close(c)
                continue
            }
            lock.lock()
            let full = live >= maxConnections
            if full { refused += 1 } else { live += 1 }
            lock.unlock()
            if full { close(c); continue }
            let t = Thread { [weak self] in
                self?.serve(HookConnection(fd: c))
                self?.lock.lock(); self?.live -= 1; self?.lock.unlock()
            }
            t.name = "crewshelf.conn"
            t.start()
        }
    }

    private func serve(_ conn: HookConnection) {
        defer { conn.finish() }
        guard case .line(let data) = readLine(conn.fd, deadline: Date().addingTimeInterval(5), maxBytes: 16 << 20),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            conn.release()
            return
        }
        switch handler(conn, obj) {
        case .close:
            conn.release()
        case .hold(let until):
            while true {
                if conn.isClosed { onRelease(conn, .decided); return }
                if Date() >= until { conn.release(); onRelease(conn, .deadline); return }
                if conn.peerGone(waitMs: max(1, min(250, msLeft(until)))) {
                    let wasDecided = conn.isClosed
                    conn.release()
                    onRelease(conn, wasDecided ? .decided : .peerGone)
                    return
                }
            }
        }
    }
}
