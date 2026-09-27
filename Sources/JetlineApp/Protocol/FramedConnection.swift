import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Kinds of frame on a Jetline connection. JSON messages carry every request,
/// response and event; terminal bytes travel raw so a chatty dev server
/// doesn't pay a JSON/base64 round trip per chunk.
enum FrameKind: UInt8, Sendable {
    /// A JSON envelope (`Wire.Request` / `Wire.Response` / `Wire.Event`).
    case message = 1
    /// Engine → client: `[u8 idLength][id][u64 offset][bytes]`.
    case terminalOutput = 2
    /// Client → engine: `[u8 idLength][id][bytes]`.
    case terminalInput = 3
    /// Forwarded TCP connections (see `TunnelMux`). Client → engine:
    /// `[u32 stream][u16 port]` — connect to that port on the engine's
    /// loopback.
    case tunnelOpen = 4
    /// Either way: `[u32 stream][bytes]`.
    case tunnelData = 5
    /// Either way: `[u32 stream][u8 how]` — 0 for end of stream (a half
    /// close), 1 for a reset.
    case tunnelClose = 6
    /// Either way: `[u32 stream][u32 bytes]` — that many bytes were
    /// delivered, so the sender may send that many more.
    case tunnelAck = 7

    var isTunnel: Bool { rawValue >= FrameKind.tunnelOpen.rawValue && rawValue <= FrameKind.tunnelAck.rawValue }
}

/// One length-prefixed frame stream over a pair of file descriptors — a
/// socketpair (local mode), a unix socket (the daemon), or the pipes of
/// `ssh host jetlined attach` (remote mode). Wire format per frame:
/// `[u32 big-endian length of kind+payload][u8 kind][payload]`.
///
/// Reads run on a private queue and hand whole frames to `onFrames` in
/// batches; writes are serialised on another queue so a slow peer never
/// blocks the caller. `pendingWriteBytes` lets the sender shed terminal
/// output when the peer falls behind (terminal streams carry offsets, so a
/// gap is recoverable).
final class FramedConnection: @unchecked Sendable {
    typealias Frame = (kind: FrameKind, payload: Data)

    static let maxFrameLength = 256 * 1024 * 1024

    private let readFD: Int32
    private let writeFD: Int32
    private let ownsFDs: Bool
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var inbox = Data()
    /// Bytes to skip up to (and including) before framing starts: a noisy
    /// remote shell can print a banner before `jetlined attach` runs.
    private var preamble: Data?
    private let lock = NSLock()
    private var closed = false
    private var _pendingWriteBytes = 0

    /// Called on the read queue with every complete frame read in one drain.
    var onFrames: (@Sendable ([Frame]) -> Void)?
    /// Called once, on the read queue, when the peer hangs up or `close()`
    /// is called.
    var onClose: (@Sendable () -> Void)?
    /// Called on the write queue when a backlog above `drainThreshold`
    /// clears — a sender that shed data while the peer was slow can catch
    /// it up now.
    var onDrained: (@Sendable () -> Void)?
    var drainThreshold = 1024 * 1024
    private var wasBacklogged = false

    init(readFD: Int32, writeFD: Int32, ownsFDs: Bool = true, label: String, preamble: Data? = nil) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.ownsFDs = ownsFDs
        self.preamble = preamble
        self.readQueue = DispatchQueue(label: "jetline.conn.read.\(label)")
        self.writeQueue = DispatchQueue(label: "jetline.conn.write.\(label)")
    }

    var pendingWriteBytes: Int { lock.withLock { _pendingWriteBytes } }
    var isClosed: Bool { lock.withLock { closed } }

    func start() {
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: readQueue)
        source.setEventHandler { [weak self] in self?.drain() }
        readSource = source
        source.resume()
    }

    func send(_ kind: FrameKind, _ payload: Data) {
        var frame = Data(capacity: payload.count + 5)
        var length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(payload)
        let size = frame.count
        let bytes = frame
        // Enqueue under the lock, so nothing can be queued after shutdown
        // queues the close.
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        _pendingWriteBytes += size
        writeQueue.async { [self] in
            let failure = writeAll(fd: writeFD, bytes)
            let drained: Bool = lock.withLock {
                _pendingWriteBytes -= size
                if _pendingWriteBytes > drainThreshold { wasBacklogged = true }
                guard wasBacklogged, _pendingWriteBytes == 0 else { return false }
                wasBacklogged = false
                return true
            }
            if drained { onDrained?() }
            if failure != nil {
                readQueue.async { self.shutdown() }
            }
        }
    }

    /// Run `body` once every frame sent so far has been written.
    func flush(_ body: @escaping @Sendable () -> Void) {
        writeQueue.async(execute: body)
    }

    func close() {
        readQueue.async { self.shutdown() }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var sawEOF = false
        while true {
            let n = read(readFD, &buffer, buffer.count)
            if n > 0 {
                inbox.append(contentsOf: buffer[0..<n])
                if n < buffer.count { break }
            } else if n == 0 {
                sawEOF = true
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                sawEOF = true
                break
            }
        }
        if let marker = preamble {
            if let found = inbox.range(of: marker) {
                inbox.removeSubrange(inbox.startIndex..<found.upperBound)
                preamble = nil
            } else {
                // Keep a tail that might be the start of the marker; give up
                // on a peer that never sends it.
                if inbox.count > 1_000_000 { sawEOF = true }
                if sawEOF { shutdown() }
                return
            }
        }
        var frames: [Frame] = []
        var offset = inbox.startIndex
        while inbox.endIndex - offset >= 4 {
            let length = inbox[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 1, length <= Self.maxFrameLength else {
                sawEOF = true
                break
            }
            guard inbox.endIndex - offset >= 4 + length else { break }
            let kindByte = inbox[offset + 4]
            let payload = inbox.subdata(in: (offset + 5)..<(offset + 4 + length))
            offset += 4 + length
            if let kind = FrameKind(rawValue: kindByte) {
                frames.append((kind, payload))
            }
        }
        if offset > inbox.startIndex {
            inbox.removeSubrange(inbox.startIndex..<offset)
        }
        if !frames.isEmpty { onFrames?(frames) }
        if sawEOF { shutdown() }
    }

    private func shutdown() {
        let wasOpen: Bool = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        let readFD = readFD, writeFD = writeFD, owns = ownsFDs
        let writeQueue = self.writeQueue
        // Close only once the read source is fully cancelled (libdispatch may
        // still be watching the fd) and every queued write is out (a final
        // response shouldn't be cut off).
        if let source = readSource {
            source.setCancelHandler {
                writeQueue.async {
                    if owns {
                        Glibc_or_Darwin_close(readFD)
                        if writeFD != readFD { Glibc_or_Darwin_close(writeFD) }
                    }
                }
            }
            source.cancel()
        } else if owns {
            writeQueue.async {
                Glibc_or_Darwin_close(readFD)
                if writeFD != readFD { Glibc_or_Darwin_close(writeFD) }
            }
        }
        readSource = nil
        onClose?()
        onClose = nil
        onFrames = nil
    }
}

@inline(__always)
private func Glibc_or_Darwin_close(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}

// MARK: - Terminal frames

enum AttachPreamble {
    /// Written by `jetlined attach` before it starts relaying.
    static let marker = Data("\u{1B}]jetline-attach;1\u{07}".utf8)
}

enum TerminalFrame {
    static func output(id: String, offset: UInt64, bytes: Data) -> Data {
        var data = Data(capacity: bytes.count + id.utf8.count + 9)
        let idBytes = Array(id.utf8.prefix(255))
        data.append(UInt8(idBytes.count))
        data.append(contentsOf: idBytes)
        var be = offset.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        data.append(bytes)
        return data
    }

    static func parseOutput(_ payload: Data) -> (id: String, offset: UInt64, bytes: Data)? {
        guard let first = payload.first else { return nil }
        let idLength = Int(first)
        let start = payload.startIndex
        guard payload.count >= 1 + idLength + 8 else { return nil }
        let id = String(decoding: payload[(start + 1)..<(start + 1 + idLength)], as: UTF8.self)
        let offsetStart = start + 1 + idLength
        let offset = payload[offsetStart..<(offsetStart + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (id, offset, payload.subdata(in: (offsetStart + 8)..<payload.endIndex))
    }

    static func input(id: String, bytes: Data) -> Data {
        var data = Data(capacity: bytes.count + id.utf8.count + 1)
        let idBytes = Array(id.utf8.prefix(255))
        data.append(UInt8(idBytes.count))
        data.append(contentsOf: idBytes)
        data.append(bytes)
        return data
    }

    static func parseInput(_ payload: Data) -> (id: String, bytes: Data)? {
        guard let first = payload.first else { return nil }
        let idLength = Int(first)
        let start = payload.startIndex
        guard payload.count >= 1 + idLength else { return nil }
        let id = String(decoding: payload[(start + 1)..<(start + 1 + idLength)], as: UTF8.self)
        return (id, payload.subdata(in: (start + 1 + idLength)..<payload.endIndex))
    }
}

// MARK: - Socket helpers

enum Sockets {
    /// A connected pair of stream sockets, for the in-process engine.
    static func pair() -> (Int32, Int32)? {
        var fds: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, type, 0, &fds) == 0 else { return nil }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            #if canImport(Darwin)
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
        }
        return (fds[0], fds[1])
    }

    private static func withSockaddr<R>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func streamSocket() -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            #if canImport(Darwin)
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
        }
        return fd
    }

    /// Connect to a unix socket. Returns the fd, or nil when nothing is
    /// listening there.
    static func connect(path: String) -> Int32? {
        let fd = streamSocket()
        guard fd >= 0 else { return nil }
        let result = withSockaddr(path: path) { addr, len in
            #if canImport(Darwin)
            Darwin.connect(fd, addr, len)
            #else
            Glibc.connect(fd, addr, len)
            #endif
        }
        guard result == 0 else {
            Glibc_or_Darwin_close(fd)
            return nil
        }
        return fd
    }

    /// Bind and listen on a unix socket, replacing a stale socket file.
    static func listen(path: String) throws -> Int32 {
        let fd = streamSocket()
        guard fd >= 0 else { throw POSIXError.current }
        unlink(path)
        let bound = withSockaddr(path: path) { addr, len in bind(fd, addr, len) }
        guard bound == 0 else {
            let error = POSIXError.current
            Glibc_or_Darwin_close(fd)
            throw error
        }
        chmod(path, 0o600)
        #if canImport(Darwin)
        let listened = Darwin.listen(fd, 16)
        #else
        let listened = Glibc.listen(fd, 16)
        #endif
        guard listened == 0 else {
            let error = POSIXError.current
            Glibc_or_Darwin_close(fd)
            throw error
        }
        return fd
    }

    static func accept(_ listener: Int32) -> Int32? {
        #if canImport(Darwin)
        let fd = Darwin.accept(listener, nil, nil)
        #else
        let fd = Glibc.accept(listener, nil, nil)
        #endif
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }
}

extension POSIXError {
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
