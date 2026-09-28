import Foundation
import CJetlineSys
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// TCP connections carried inside a Jetline connection, for port
/// forwarding: the app listens on `localhost:<port>` and each connection it
/// accepts becomes a stream here; the engine connects the other end to the
/// same port on its own loopback. Riding the existing link means forwarding
/// works over whatever carries it (plain ssh, a jump host, `docker exec`)
/// with no second login.
///
/// Both ends run one of these. Every stream has a flow-control window per
/// direction: a side sends at most `window` bytes the peer hasn't
/// acknowledged, and stops reading its socket until acks come back — so a
/// big download can't pile up in the connection's write queue ahead of
/// terminal output, and a slow browser slows the remote server down rather
/// than filling memory.
///
/// All state lives on one private queue. Frames come in through `receive`
/// (from the connection's read queue, in order) and go out through `send`.
///
/// On Linux a dispatch source doesn't report readiness that was already
/// there when it was resumed, or that a handler left unconsumed. So a
/// stream never relies on that: resuming a source always polls once
/// (`resumeReading`, `armWriting`), and a read that stops before `EAGAIN`
/// comes back for the rest itself.
final class TunnelMux: @unchecked Sendable {
    static let window = 1 << 20
    private static let readChunk = 64 * 1024
    /// Acknowledge in batches of this much (or whenever the socket's write
    /// backlog empties).
    private static let ackBatch = 64 * 1024

    private let queue: DispatchQueue
    private let label: String
    private let sendFrame: @Sendable (FrameKind, Data) -> Void
    private var streams: [UInt32: Stream] = [:]
    /// Engine side: streams whose connect is still in flight, holding what
    /// the client sent meanwhile.
    private var connecting: [UInt32: PendingStream] = [:]
    private var nextId: UInt32 = 1
    private var isClosed = false
    /// Shared by every read: all of them run on `queue`.
    private var readBuffer = [UInt8](repeating: 0, count: TunnelMux.readChunk)
    /// Engine side: connect a stream the client opened. Called off the mux
    /// queue (it may block); returns a connected socket, or nil to refuse.
    private let connect: (@Sendable (_ port: Int) -> Int32?)?

    /// `JETLINE_TUNNEL_TRACE=1`: log every stream event to stderr.
    private static let tracing = ProcessInfo.processInfo.environment["JETLINE_TUNNEL_TRACE"] == "1"

    /// Streams currently open, for tests and diagnostics.
    var openStreamCount: Int { queue.sync { streams.count } }

    init(label: String, connect: (@Sendable (_ port: Int) -> Int32?)? = nil, send: @escaping @Sendable (FrameKind, Data) -> Void) {
        self.queue = DispatchQueue(label: "jetline.tunnel.\(label)")
        self.label = label
        self.connect = connect
        self.sendFrame = send
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard Self.tracing else { return }
        FileHandle.standardError.write(Data("tunnel[\(label)] \(message())\n".utf8))
    }

    private func send(_ kind: FrameKind, _ payload: Data) {
        if kind != .tunnelData { trace("send \(kind) \([UInt8](payload.prefix(9)))") }
        sendFrame(kind, payload)
    }

    // MARK: Opening

    /// Client side: carry `fd` (an accepted local connection) to `port` on
    /// the engine's machine. Takes ownership of the socket.
    func open(fd: Int32, port: Int) {
        queue.async { [self] in
            guard !isClosed else {
                Glibc_or_Darwin_close(fd)
                return
            }
            let id = nextId
            nextId &+= 1
            var payload = Self.header(id)
            payload.appendBigEndian(UInt16(port))
            send(.tunnelOpen, payload)
            adopt(fd, id: id)
        }
    }

    /// Drop every stream (the link went away). Sockets are reset, so a
    /// browser sees the failure at once instead of hanging.
    func close() {
        queue.async { [self] in
            isClosed = true
            for stream in Array(streams.values) { teardown(stream, reset: true) }
        }
    }

    // MARK: Frames in

    func receive(_ kind: FrameKind, _ payload: Data) {
        guard let id = payload.bigEndian(UInt32.self, at: 0) else { return }
        // A slice: the body is queued without copying.
        let body = payload.dropFirst(4)
        queue.async { [self] in
            guard !isClosed else { return }
            if kind != .tunnelData { trace("recv \(kind) \(id) \([UInt8](body.prefix(4))) known=\(streams[id] != nil)") }
            switch kind {
            case .tunnelOpen:
                beginConnect(id, port: body.bigEndian(UInt16.self, at: 0).map(Int.init) ?? 0)
            case .tunnelData:
                if let stream = streams[id] {
                    stream.outbox.append(body)
                    flushWrites(stream)
                } else {
                    connecting[id]?.outbox.append(body)
                }
            case .tunnelClose:
                let finished = body.first == 0
                if let stream = streams[id] {
                    if finished {
                        stream.peerFinished = true
                        flushWrites(stream)
                    } else {
                        teardown(stream, reset: true)
                    }
                } else if let pending = connecting[id] {
                    if finished { pending.peerFinished = true } else { pending.cancelled = true }
                }
            case .tunnelAck:
                guard let stream = streams[id], let count = body.bigEndian(UInt32.self, at: 0) else { return }
                stream.unacked = max(0, stream.unacked - Int(count))
                if stream.readPaused, !stream.localFinished, stream.unacked < Self.window {
                    resumeReading(stream)
                }
            default:
                return
            }
        }
    }

    /// Engine side. Connecting can block (a listener with a full backlog),
    /// so it runs elsewhere; the stream's other traffic waits in `connecting`.
    private func beginConnect(_ id: UInt32, port: Int) {
        guard port > 0, streams[id] == nil, connecting[id] == nil, let connect else {
            send(.tunnelClose, Self.header(id) + [1])
            return
        }
        connecting[id] = PendingStream()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fd = connect(port)
            queue.async { [self] in
                guard let pending = connecting.removeValue(forKey: id), !isClosed, !pending.cancelled, let fd else {
                    if let fd { Glibc_or_Darwin_close(fd) }
                    if !isClosed { send(.tunnelClose, Self.header(id) + [1]) }
                    return
                }
                let stream = adopt(fd, id: id)
                stream.outbox = pending.outbox
                stream.peerFinished = pending.peerFinished
                flushWrites(stream)
            }
        }
    }

    // MARK: Streams

    private final class PendingStream {
        var outbox: [Data] = []
        var peerFinished = false
        var cancelled = false
    }

    private final class Stream {
        let id: UInt32
        let fd: Int32
        let readSource: DispatchSourceRead
        let writeSource: DispatchSourceWrite
        var readPaused = false
        var writeArmed = false
        /// Bytes from the peer not yet written to the socket.
        var outbox: [Data] = []
        /// Sent to the peer and not yet acknowledged.
        var unacked = 0
        /// Written to the socket and not yet acknowledged to the peer.
        var toAck = 0
        /// Our socket reached EOF; the peer has been told.
        var localFinished = false
        /// The peer's side ended; our socket's write side is shut once the
        /// outbox drains.
        var peerFinished = false
        var shutWrite = false

        init(id: UInt32, fd: Int32, readSource: DispatchSourceRead, writeSource: DispatchSourceWrite) {
            self.id = id
            self.fd = fd
            self.readSource = readSource
            self.writeSource = writeSource
        }
    }

    @discardableResult
    private func adopt(_ fd: Int32, id: UInt32) -> Stream {
        trace("adopt \(id) fd\(fd)")
        jl_tcp_prepare(fd)
        let stream = Stream(
            id: id,
            fd: fd,
            readSource: DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue),
            writeSource: DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        )
        streams[id] = stream
        stream.readSource.setEventHandler { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.readable(stream)
        }
        stream.writeSource.setEventHandler { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.flushWrites(stream)
        }
        stream.readSource.resume()
        return stream
    }

    private func readable(_ stream: Stream) {
        guard streams[stream.id] === stream, !stream.localFinished else { return }
        // A few chunks per wakeup, so one busy stream doesn't hog the queue.
        for _ in 0..<4 {
            let room = Self.window - stream.unacked
            guard room > 0 else { break }
            let n = read(stream.fd, &readBuffer, min(readBuffer.count, room))
            if n > 0 {
                trace("read \(stream.id) \(n) unacked=\(stream.unacked + n)")
                stream.unacked += n
                var payload = Self.header(stream.id, reserving: n)
                payload.append(contentsOf: readBuffer[0..<n])
                send(.tunnelData, payload)
            } else if n == 0 {
                trace("eof \(stream.id)")
                stream.localFinished = true
                pauseReading(stream)
                send(.tunnelClose, Self.header(stream.id) + [0])
                finishIfDone(stream)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                trace("read error \(stream.id) errno \(errno)")
                reset(stream)
                return
            }
        }
        if stream.unacked >= Self.window {
            pauseReading(stream)
        } else {
            // Out of budget, not out of data: come back for the rest.
            poll(stream) { $0.readable($1) }
        }
    }

    private func pauseReading(_ stream: Stream) {
        guard !stream.readPaused else { return }
        stream.readPaused = true
        stream.readSource.suspend()
    }

    private func resumeReading(_ stream: Stream) {
        stream.readPaused = false
        stream.readSource.resume()
        poll(stream) { $0.readable($1) }
    }

    private func armWriting(_ stream: Stream) {
        guard !stream.writeArmed else { return }
        stream.writeArmed = true
        stream.writeSource.resume()
        poll(stream) { $0.flushWrites($1) }
    }

    /// Run `step` for `stream` once more, soon, if it's still open.
    private func poll(_ stream: Stream, _ step: @escaping @Sendable (TunnelMux, Stream) -> Void) {
        let id = stream.id
        queue.async { [weak self] in
            guard let self, let stream = self.streams[id] else { return }
            step(self, stream)
        }
    }

    private func flushWrites(_ stream: Stream) {
        guard streams[stream.id] === stream else { return }
        while let chunk = stream.outbox.first {
            let n = chunk.withUnsafeBytes { raw in
                jl_send(stream.fd, raw.baseAddress, UInt(raw.count))
            }
            if n > 0 {
                trace("wrote \(stream.id) \(n)/\(chunk.count)")
                stream.toAck += n
                if n == chunk.count {
                    stream.outbox.removeFirst()
                } else {
                    stream.outbox[0] = chunk.dropFirst(n)
                }
                if stream.toAck >= Self.ackBatch { acknowledge(stream) }
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armWriting(stream)
                return
            } else {
                trace("write error \(stream.id) errno \(errno)")
                reset(stream)
                return
            }
        }
        if stream.writeArmed {
            stream.writeArmed = false
            stream.writeSource.suspend()
        }
        if stream.toAck > 0 { acknowledge(stream) }
        if stream.peerFinished, !stream.shutWrite {
            stream.shutWrite = true
            _ = shutdown(stream.fd, Int32(SHUT_WR))
        }
        finishIfDone(stream)
    }

    private func acknowledge(_ stream: Stream) {
        var payload = Self.header(stream.id)
        payload.appendBigEndian(UInt32(stream.toAck))
        stream.toAck = 0
        send(.tunnelAck, payload)
    }

    private func finishIfDone(_ stream: Stream) {
        if stream.localFinished, stream.shutWrite { teardown(stream, reset: false) }
    }

    /// Our socket failed: reset both ends.
    private func reset(_ stream: Stream) {
        send(.tunnelClose, Self.header(stream.id) + [1])
        teardown(stream, reset: true)
    }

    private func teardown(_ stream: Stream, reset: Bool) {
        guard streams[stream.id] === stream else { return }
        trace("teardown \(stream.id) reset=\(reset)")
        streams[stream.id] = nil
        if reset { jl_tcp_abort_on_close(stream.fd) }
        // Close only once both sources are cancelled — libdispatch may still
        // be watching the fd. A suspended source must be resumed to cancel.
        let group = DispatchGroup()
        for source in [stream.readSource as DispatchSourceProtocol, stream.writeSource] {
            group.enter()
            source.setCancelHandler { group.leave() }
            source.cancel()
        }
        if stream.readPaused { stream.readSource.resume() }
        if !stream.writeArmed { stream.writeSource.resume() }
        let fd = stream.fd
        group.notify(queue: queue) { Glibc_or_Darwin_close(fd) }
    }

    private static func header(_ id: UInt32, reserving extra: Int = 4) -> Data {
        var data = Data(capacity: 4 + extra)
        data.appendBigEndian(id)
        return data
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    /// The big-endian integer `offset` bytes into this (possibly sliced)
    /// data, or nil if it's too short.
    func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard count >= offset + size else { return nil }
        let start = startIndex + offset
        return self[start..<(start + size)].reduce(T(0)) { $0 << 8 | T($1) }
    }
}

/// Where tunnel frames go — set once the link is up, read from the
/// connection's read queue.
final class TunnelRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var _mux: TunnelMux?

    var mux: TunnelMux? {
        get { lock.withLock { _mux } }
        set { lock.withLock { _mux = newValue } }
    }
}

// MARK: - Listening on this machine

/// `localhost:<port>` on this machine — both 127.0.0.1 and ::1, since
/// browsers try either for "localhost" — handing every connection to
/// `onAccept`.
final class LoopbackListener: @unchecked Sendable {
    private let queue: DispatchQueue
    private var sources: [DispatchSourceRead] = []

    enum Failure: Error, Equatable {
        /// Something on this machine is already listening there.
        case inUse
        case other(String)

        var message: String {
            switch self {
            case .inUse: return "In use on this Mac"
            case let .other(text): return text
            }
        }
    }

    /// Binds at once; throws `Failure`.
    init(port: Int, onAccept: @escaping @Sendable (Int32) -> Void) throws(Failure) {
        self.queue = DispatchQueue(label: "jetline.listen.\(port)")
        let v4 = try Self.bind(family: 4, port: port)
        var fds = [v4]
        do {
            fds.append(try Self.bind(family: 6, port: port))
        } catch .inUse {
            // A local server on [::1] would take the browser's first try.
            Glibc_or_Darwin_close(v4)
            throw .inUse
        } catch {
            // No IPv6 loopback here; 127.0.0.1 is enough.
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                while true {
                    let client = jl_accept(fd)
                    guard client >= 0 else { return }
                    onAccept(client)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Closes the sockets (their sources own them from `init` on) and
    /// returns once they're closed, so the port can usually be bound
    /// again at once (forwarding switched back on, another remote taking
    /// it over). Usually: a subprocess being spawned at that instant holds
    /// a copy until its exec, a millisecond or two.
    func close() {
        guard !sources.isEmpty else { return }
        let released = DispatchGroup()
        for source in sources {
            released.enter()
            let fd = Int32(source.handle)
            source.setCancelHandler {
                Glibc_or_Darwin_close(fd)
                released.leave()
            }
            source.cancel()
        }
        sources = []
        _ = released.wait(timeout: .now() + 2)
    }

    deinit { close() }

    private static func bind(family: Int32, port: Int) throws(Failure) -> Int32 {
        let fd = jl_tcp_listen_loopback(family, Int32(port), 0)
        if fd >= 0 { return fd }
        guard -fd == EADDRINUSE else { throw .other(String(cString: strerror(-fd))) }
        // Held by a listener, or only by connections of ours lingering in
        // TIME_WAIT from an earlier forward? Only the latter may be reused.
        // Briefly: this runs on the main thread, and a listener with a full
        // backlog never answers (that's a listener too).
        let probe = jl_tcp_connect(family == 6 ? "::1" : "127.0.0.1", Int32(port), 250)
        if probe >= 0 || -probe == ETIMEDOUT {
            if probe >= 0 { Glibc_or_Darwin_close(probe) }
            throw .inUse
        }
        let retry = jl_tcp_listen_loopback(family, Int32(port), 1)
        if retry >= 0 { return retry }
        throw -retry == EADDRINUSE ? .inUse : .other(String(cString: strerror(-retry)))
    }
}
