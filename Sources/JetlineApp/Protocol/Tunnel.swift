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
final class TunnelMux: @unchecked Sendable {
    static let window = 1 << 20
    private static let readChunk = 64 * 1024
    /// Acknowledge in batches of this much (or whenever the socket's write
    /// backlog empties).
    private static let ackBatch = 64 * 1024

    private let queue: DispatchQueue
    private let label: String
    private let sendFrame: @Sendable (FrameKind, Data) -> Void
    /// `JETLINE_TUNNEL_TRACE=1`: log every stream event to stderr.
    private static let tracing = ProcessInfo.processInfo.environment["JETLINE_TUNNEL_TRACE"] == "1"

    private func trace(_ message: @autoclosure () -> String) {
        guard Self.tracing else { return }
        FileHandle.standardError.write(Data("tunnel[\(label)] \(message())\n".utf8))
    }

    private func send(_ kind: FrameKind, _ payload: Data) {
        if Self.tracing, kind != .tunnelData {
            trace("send \(kind) \(payload.count)b \([UInt8](payload.prefix(9)))")
        }
        sendFrame(kind, payload)
    }
    private var streams: [UInt32: Stream] = [:]
    private var nextId: UInt32 = 1
    private var isClosed = false
    /// Engine side: connect a stream the client opened. Called on the mux
    /// queue; returns a connected socket, or nil to refuse.
    private let connect: (@Sendable (_ port: Int) -> Int32?)?

    /// Streams currently open, for tests and diagnostics.
    var openStreamCount: Int { queue.sync { streams.count } }

    init(label: String, connect: (@Sendable (_ port: Int) -> Int32?)? = nil, send: @escaping @Sendable (FrameKind, Data) -> Void) {
        self.queue = DispatchQueue(label: "jetline.tunnel.\(label)")
        self.label = label
        self.connect = connect
        self.sendFrame = send
    }

    // MARK: Opening

    /// Client side: carry `fd` (an accepted local connection) to `port` on
    /// the engine's machine. Takes ownership of the socket.
    func open(fd: Int32, port: Int) {
        queue.async { [self] in
            guard !isClosed else {
                Self.closeSocket(fd)
                return
            }
            let id = nextId
            nextId &+= 1
            var payload = Self.header(id)
            var bePort = UInt16(port).bigEndian
            withUnsafeBytes(of: &bePort) { payload.append(contentsOf: $0) }
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
        guard payload.count >= 4 else { return }
        let bytes = [UInt8](payload)
        let id = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        queue.async { [self] in
            guard !isClosed else { return }
            if Self.tracing, kind != .tunnelData { trace("recv \(kind) \(bytes.prefix(9)) known=\(streams[id] != nil)") }
            switch kind {
            case .tunnelOpen:
                guard bytes.count >= 6 else { return }
                let port = Int(bytes[4]) << 8 | Int(bytes[5])
                guard port > 0, streams[id] == nil, let fd = connect?(port) else {
                    send(.tunnelClose, Self.header(id) + [1])
                    return
                }
                adopt(fd, id: id)
            case .tunnelData:
                guard let stream = streams[id] else { return }
                stream.outbox.append(Data(bytes[4...]))
                flushWrites(stream)
            case .tunnelClose:
                guard let stream = streams[id] else { return }
                if bytes.count >= 5, bytes[4] == 0 {
                    stream.peerFinished = true
                    flushWrites(stream)
                } else {
                    teardown(stream, reset: true)
                }
            case .tunnelAck:
                guard let stream = streams[id], bytes.count >= 8 else { return }
                let count = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
                stream.unacked = max(0, stream.unacked - count)
                if stream.readPaused, !stream.localFinished, stream.unacked < Self.window {
                    stream.readPaused = false
                    stream.readSource.resume()
                    // Linux's libdispatch doesn't fire a resumed source for
                    // data that arrived while it was suspended; if the peer
                    // is stalled on us, nothing new would ever come.
                    readable(stream)
                }
            default:
                return
            }
        }
    }

    // MARK: Streams

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

    private func adopt(_ fd: Int32, id: UInt32) {
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
    }

    private func readable(_ stream: Stream) {
        guard streams[stream.id] === stream, !stream.localFinished else { return }
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        // A few chunks per wakeup, so one busy stream doesn't hog the queue.
        for _ in 0..<4 {
            let room = Self.window - stream.unacked
            guard room > 0 else { break }
            let n = read(stream.fd, &buffer, min(buffer.count, room))
            if n > 0 {
                trace("read \(stream.id) fd\(stream.fd) \(n) unacked=\(stream.unacked + n)")
                stream.unacked += n
                var payload = Self.header(stream.id)
                payload.append(contentsOf: buffer[0..<n])
                send(.tunnelData, payload)
            } else if n == 0 {
                trace("eof \(stream.id) fd\(stream.fd)")
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
                send(.tunnelClose, Self.header(stream.id) + [1])
                teardown(stream, reset: true)
                return
            }
        }
        if stream.unacked >= Self.window {
            pauseReading(stream)
        } else {
            // Out of budget with data likely left. Come back for it rather
            // than wait for the source: on Linux it fires on new data only,
            // not on data still sitting there.
            let id = stream.id
            queue.async { [weak self] in
                guard let self, let stream = self.streams[id] else { return }
                self.readable(stream)
            }
        }
    }

    private func pauseReading(_ stream: Stream) {
        guard !stream.readPaused else { return }
        stream.readPaused = true
        stream.readSource.suspend()
    }

    private func flushWrites(_ stream: Stream) {
        guard streams[stream.id] === stream else { return }
        while let chunk = stream.outbox.first {
            let n = chunk.withUnsafeBytes { raw in
                jl_send(stream.fd, raw.baseAddress, UInt(raw.count))
            }
            if n > 0 {
                trace("wrote \(stream.id) fd\(stream.fd) \(n)/\(chunk.count) queued=\(stream.outbox.count)")
                stream.toAck += n
                if n == chunk.count {
                    stream.outbox.removeFirst()
                } else {
                    stream.outbox[0] = chunk.subdata(in: (chunk.startIndex + n)..<chunk.endIndex)
                }
                if stream.toAck >= Self.ackBatch { acknowledge(stream) }
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                trace("write blocked \(stream.id) armed=\(stream.writeArmed)")
                if !stream.writeArmed {
                    stream.writeArmed = true
                    stream.writeSource.resume()
                }
                return
            } else {
                trace("write error \(stream.id) errno \(errno)")
                send(.tunnelClose, Self.header(stream.id) + [1])
                teardown(stream, reset: true)
                return
            }
        }
        if stream.writeArmed {
            stream.writeArmed = false
            stream.writeSource.suspend()
        }
        if stream.toAck > 0 { acknowledge(stream) }
        if stream.peerFinished, !stream.shutWrite {
            trace("shutdown write \(stream.id) fd\(stream.fd)")
            stream.shutWrite = true
            _ = shutdown(stream.fd, Int32(SHUT_WR))
        }
        finishIfDone(stream)
    }

    private func acknowledge(_ stream: Stream) {
        var payload = Self.header(stream.id)
        var count = UInt32(stream.toAck).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        stream.toAck = 0
        send(.tunnelAck, payload)
    }

    private func finishIfDone(_ stream: Stream) {
        if stream.localFinished, stream.shutWrite { teardown(stream, reset: false) }
    }

    private func teardown(_ stream: Stream, reset: Bool) {
        guard streams[stream.id] === stream else { return }
        trace("teardown \(stream.id) fd\(stream.fd) reset=\(reset)")
        streams[stream.id] = nil
        if reset { jl_tcp_abort_on_close(stream.fd) }
        // Close only once both sources are cancelled — libdispatch may still
        // be watching the fd. A suspended source must be resumed to cancel.
        let group = DispatchGroup()
        let fd = stream.fd
        for source in [stream.readSource as DispatchSourceProtocol, stream.writeSource] {
            group.enter()
            source.setCancelHandler { group.leave() }
            source.cancel()
        }
        if stream.readPaused { stream.readSource.resume() }
        if !stream.writeArmed { stream.writeSource.resume() }
        group.notify(queue: queue) { [self] in
            trace("closed fd\(fd)")
            Self.closeSocket(fd)
        }
    }

    private static func header(_ id: UInt32) -> Data {
        var be = id.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    static func closeSocket(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
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
    let port: Int
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
        self.port = port
        self.queue = DispatchQueue(label: "jetline.listen.\(port)")
        let v4 = try Self.bind(family: 4, port: port)
        var fds = [v4]
        do {
            fds.append(try Self.bind(family: 6, port: port))
        } catch .inUse {
            // A local server on [::1] would take the browser's first try.
            TunnelMux.closeSocket(v4)
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
            source.setCancelHandler { TunnelMux.closeSocket(fd) }
            source.resume()
            sources.append(source)
        }
    }

    /// Returns once the socket is closed, so the port can usually be bound
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
                TunnelMux.closeSocket(fd)
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
            if probe >= 0 { TunnelMux.closeSocket(probe) }
            throw .inUse
        }
        let retry = jl_tcp_listen_loopback(family, Int32(port), 1)
        if retry >= 0 { return retry }
        throw -retry == EADDRINUSE ? .inUse : .other(String(cString: strerror(-retry)))
    }
}
