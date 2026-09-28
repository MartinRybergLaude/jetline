import XCTest
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

enum TestSupport {
    /// A throwaway `JETLINE_DATA_DIR` for the whole test run, set before
    /// anything touches `Database.shared` — never the real ~/.jetline.
    /// realpath, not resolvingSymlinksInPath: the latter maps macOS's
    /// /private/var back to /var, and git reports the real path.
    static let dataDir: URL = {
        let tmp = realpath(FileManager.default.temporaryDirectory.path, nil).map { p in defer { free(p) }; return String(cString: p) }
            ?? FileManager.default.temporaryDirectory.path
        let dir = URL(fileURLWithPath: tmp).appendingPathComponent("jetline-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JETLINE_DATA_DIR", dir.path, 1)
        return dir
    }()

    /// A fresh engine served over a socketpair — the path the Mac app and
    /// `jetlined` use — and a started client on the other end.
    @MainActor
    static func engineAndClient(
        tunnelConnect: EngineServer.TunnelConnect? = nil,
        onEvent: @escaping (EngineEvent) -> Void
    ) throws -> (EngineServer, EngineClient) {
        let server = EngineServer(engine: Engine(), engineVersion: "test", tunnelConnect: tunnelConnect)
        let (a, b) = try XCTUnwrap(Sockets.pair())
        server.accept(FramedConnection(readFD: a, writeFD: a, label: "test-server"))
        let client = EngineClient(connection: FramedConnection(readFD: b, writeFD: b, label: "test-client"))
        client.onEvent = onEvent
        client.start()
        return (server, client)
    }

    /// Another client on an existing server.
    @MainActor
    static func connect(to server: EngineServer, onEvent: @escaping (EngineEvent) -> Void = { _ in }) throws -> EngineClient {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        server.accept(FramedConnection(readFD: a, writeFD: a, label: "test-server"))
        let client = EngineClient(connection: FramedConnection(readFD: b, writeFD: b, label: "test-client"))
        client.onEvent = onEvent
        client.start()
        return client
    }

    /// A git repository with one commit on `main`, under `dataDir`.
    static func makeRepo() async throws -> String {
        let dir = dataDir.appendingPathComponent("repo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Test User"], ["config", "user.email", "t@example.com"]] {
            _ = try await GitRunner.runChecked(args, cwd: dir.path)
        }
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await GitRunner.runChecked(["add", "."], cwd: dir.path)
        _ = try await GitRunner.runChecked(["commit", "-q", "-m", "init"], cwd: dir.path)
        return dir.path
    }
}

/// A value shared with callbacks on other queues.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&_value) } }
}

enum TestIO {
    /// On its own thread: these block, and the cooperative pool may have
    /// only a couple.
    static func background<T: Sendable>(_ body: @escaping @Sendable () -> T) -> Task<T, Never> {
        Task {
            await withCheckedContinuation { continuation in
                Thread { continuation.resume(returning: body()) }.start()
            }
        }
    }

    /// Until EOF (or an error), or `silence` seconds with nothing to read.
    static func readToEnd(_ fd: Int32, silence: Int32 = 20) async -> Data {
        await background {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, silence * 1000) > 0 else { return data }
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    data.append(contentsOf: buffer[0..<n])
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return data
                }
            }
        }.value
    }

    /// Exactly `count` bytes, or fewer if the fd ends or stays quiet for
    /// `timeout` ms.
    static func readExactly(_ fd: Int32, count: Int, timeout: Int32 = 5000) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < count {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, timeout) > 0 else { break }
            let n = read(fd, &buffer, min(buffer.count, count - data.count))
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    /// A frame as it goes over the wire: `[u32 length][u8 kind][payload]`.
    static func frame(kind: UInt8, _ payload: Data) -> Data {
        var data = Data()
        var length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(kind)
        data.append(payload)
        return data
    }

    static func frame(_ kind: FrameKind, _ payload: Data) -> Data {
        frame(kind: kind.rawValue, payload)
    }

    static func frame(json: String) -> Data {
        frame(.message, Data(json.utf8))
    }
}

/// Poll `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
