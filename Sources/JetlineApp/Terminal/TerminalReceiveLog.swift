import Foundation

/// Persistent breadcrumbs around libghostty terminal writes.
///
/// The important case is a freeze inside `session.receive(data)`: we write a
/// `begin` record before entering libghostty, an `end` record after returning,
/// and a background `stalled` record if the write has not returned quickly.
/// That leaves disk evidence even when the main thread wedges.
enum TerminalReceiveLog {
    struct Token {
        let id: UInt64
        let sessionId: UInt64
        let started: DispatchTime
    }

    private struct ActiveWrite {
        let sessionId: UInt64
        let started: DispatchTime
        let bytes: Int
        let preview: String
    }

    private static let capBytes: UInt64 = 5 * 1024 * 1024
    private static let stallWarningNanos: UInt64 = 2_000_000_000

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var nextSession: UInt64 = 0
        var nextWrite: UInt64 = 0
        var handle: FileHandle?
        var currentBytes: UInt64 = 0
        var active: [UInt64: ActiveWrite] = [:]
    }

    private static let store = Store()

    static var logURL: URL {
        dataDirectory().appendingPathComponent("jetline-terminal-receive.log")
    }

    static func makeSessionId() -> UInt64 {
        store.lock.lock()
        defer { store.lock.unlock() }
        store.nextSession += 1
        return store.nextSession
    }

    static func processStarted(sessionId: UInt64, executable: String, cwd: String) {
        write("process session=\(sessionId) executable=\(quote(executable)) cwd=\(quote(cwd))")
    }

    static func begin(sessionId: UInt64, data: Data) -> Token {
        let token: Token
        let activeWrite: ActiveWrite
        store.lock.lock()
        store.nextWrite += 1
        token = Token(id: store.nextWrite, sessionId: sessionId, started: .now())
        activeWrite = ActiveWrite(
            sessionId: sessionId,
            started: token.started,
            bytes: data.count,
            preview: describe(data)
        )
        store.active[token.id] = activeWrite
        store.lock.unlock()

        write("begin id=\(token.id) session=\(sessionId) bytes=\(data.count) preview=\(quote(activeWrite.preview))")
        scheduleStallWarning(id: token.id)
        return token
    }

    static func end(_ token: Token) {
        let duration = elapsedMilliseconds(since: token.started)
        store.lock.lock()
        store.active.removeValue(forKey: token.id)
        store.lock.unlock()
        write("end id=\(token.id) session=\(token.sessionId) durationMs=\(format(duration))")
    }

    static func receiveFailed(sessionId: UInt64, message: String) {
        write("receive-failed session=\(sessionId) message=\(quote(message))")
    }

    static func droppedTitleUpdate(sessionId: UInt64, data: Data) {
        write("drop-title-update session=\(sessionId) bytes=\(data.count) preview=\(quote(describe(data)))")
    }

    private static func scheduleStallWarning(id: UInt64) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(stallWarningNanos))) {
            store.lock.lock()
            let item = store.active[id]
            store.lock.unlock()

            guard let item else { return }
            let duration = elapsedMilliseconds(since: item.started)
            write(
                "stalled id=\(id) session=\(item.sessionId) durationMs=\(format(duration)) bytes=\(item.bytes) preview=\(quote(item.preview))"
            )
        }
    }

    private static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        store.lock.lock()
        defer { store.lock.unlock() }

        do {
            try prepareHandleLocked(extraBytes: UInt64(data.count))
            store.handle?.write(data)
            store.currentBytes += UInt64(data.count)
        } catch {
            // Logging must never interfere with terminal I/O.
            store.handle = nil
            store.currentBytes = 0
        }
    }

    private static func prepareHandleLocked(extraBytes: UInt64) throws {
        let url = logURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if store.handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            store.handle = try FileHandle(forWritingTo: url)
            try store.handle?.seekToEnd()
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                store.currentBytes = size.uint64Value
            } else {
                store.currentBytes = 0
            }
        }

        guard store.currentBytes + extraBytes > capBytes else { return }

        try store.handle?.close()
        store.handle = nil
        let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotated)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: rotated)
        }
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        store.handle = try FileHandle(forWritingTo: url)
        store.currentBytes = 0
    }

    private static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["JETLINE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jetline", isDirectory: true)
    }

    private static func elapsedMilliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func timestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }

    private static func describe(_ data: Data, limit: Int = 160) -> String {
        let preview = data.prefix(limit)
        let text = String(decoding: preview, as: UTF8.self)
        let suffix = data.count > limit ? "..." : ""
        return escaped(text) + suffix
    }

    private static func quote(_ value: String) -> String {
        "\"\(escaped(value))\""
    }

    private static func escaped(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x09:
                out += "\\t"
            case 0x0A:
                out += "\\n"
            case 0x0D:
                out += "\\r"
            case 0x1B:
                out += "\\e"
            case 0x22:
                out += "\\\""
            case 0x5C:
                out += "\\\\"
            case 0x20 ..< 0x7F:
                out.append(Character(scalar))
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u{%02X}", Int(scalar.value))
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        return out
    }
}
