import XCTest
import CJetlineSys
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

/// Port forwarding over a real `EngineServer` / `EngineClient` pair: the
/// tunnel multiplexer, the port scanner, and the Mac-side forwarder.
@MainActor
final class PortForwardingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Like the daemon: a peer that hung up must be an error, not a
        // signal (Linux has no per-socket SO_NOSIGPIPE).
        signal(SIGPIPE, SIG_IGN)
        if ProcessInfo.processInfo.environment["JETLINE_DATA_DIR"] == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            setenv("JETLINE_DATA_DIR", dir.path, 1)
        }
    }

    private var server: EngineServer!
    private var client: EngineClient!
    private var events: [EngineEvent] = []

    /// The engine side's connect, for tests that need the far end
    /// somewhere other than this machine's loopback (which, with app and
    /// engine on one machine, is the forwarder itself).
    nonisolated(unsafe) private static var farEnd: [Int: Int] = [:]

    override func setUp() async throws {
        Self.farEnd = [:]
        server = EngineServer(engine: Engine(), engineVersion: "test", tunnelConnect: { port in
            let target = PortForwardingTests.farEnd[port] ?? port
            let fd = jl_tcp_connect("127.0.0.1", Int32(target), 2000)
            return fd >= 0 ? fd : nil
        })
        let (a, b) = try XCTUnwrap(Sockets.pair())
        server.accept(FramedConnection(readFD: a, writeFD: a, label: "test-server"))
        client = EngineClient(connection: FramedConnection(readFD: b, writeFD: b, label: "test-client"))
        client.onEvent = { [weak self] event in self?.events.append(event) }
        client.start()
    }

    override func tearDown() async throws {
        client.close()
        await server.engine.shutdown()
    }

    private func hello() async throws -> API.HelloResult {
        try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "test"))
    }

    private func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Tunnels

    func testForwardedConnectionCarriesBytesBothWaysAndHalfCloses() async throws {
        let hello = try await hello()
        XCTAssertEqual(hello.features, [API.tunnelsFeature])
        let (listener, port) = try Self.listenAnyPort()
        defer { _ = close(listener) }
        // The "dev server": echo everything back, then close once the
        // client is done sending.
        let serverDone = Self.background {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { _ = close(fd) }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                _ = buffer.withUnsafeBytes { writeAll(fd: fd, $0.baseAddress!, count: n) }
            }
        }
        let (local, app) = try XCTUnwrap(Sockets.pair())
        client.tunnels().open(fd: app, port: port)

        // Several windows' worth, so flow control has to kick in.
        var payload = Data(count: 5 * TunnelMux.window + 12345)
        for i in payload.indices { payload[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let sent = payload
        let writer = Self.background {
            _ = writeAll(fd: local, sent)
            _ = shutdown(local, Int32(SHUT_WR))
        }
        let received = await Self.readToEnd(local)
        await writer.value
        await serverDone.value
        _ = close(local)
        XCTAssertEqual(received.count, payload.count)
        XCTAssertTrue(received == payload, "echoed bytes differ")
        await eventually("streams to close") { client.tunnels().openStreamCount == 0 }
    }

    func testConnectionToAClosedPortIsRefused() async throws {
        _ = try await hello()
        let (listener, port) = try Self.listenAnyPort()
        _ = close(listener)
        let (local, app) = try XCTUnwrap(Sockets.pair())
        client.tunnels().open(fd: app, port: port)
        let received = await Self.readToEnd(local)
        _ = close(local)
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: Ports

    func testScannerReportsTheUsersListeners() async throws {
        let (listener, port) = try Self.listenAnyPort(inRange: 20000..<29000)
        defer { _ = close(listener) }
        let ports = try await {
            _ = try await hello()
            return try await client.call(API.WatchPorts())
        }()
        let found = try XCTUnwrap(ports.first { $0.port == port }, "\(port) not in \(ports.map(\.port))")
        XCTAssertEqual(found.addresses, ["127.0.0.1"])
        XCTAssertTrue(found.suggested)

        // A new listener shows up as an event.
        let (second, secondPort) = try Self.listenAnyPort(inRange: 20000..<29000)
        await eventually("a ports event with \(secondPort)") {
            events.contains { if case let .ports(list) = $0 { list.contains { $0.port == secondPort } } else { false } }
        }
        _ = close(second)
        await eventually("\(secondPort) to go away") {
            guard case let .ports(list)? = events.last(where: { if case .ports = $0 { true } else { false } }) else { return false }
            return !list.contains { $0.port == secondPort }
        }
    }

    #if os(Linux)
    func testProcAddressParsing() {
        XCTAssertEqual(PortScanner.procAddress("0100007F", v6: false), "127.0.0.1")
        XCTAssertEqual(PortScanner.procAddress("00000000", v6: false), "0.0.0.0")
        XCTAssertEqual(PortScanner.procAddress("00000000000000000000000001000000", v6: true), "::1")
        XCTAssertEqual(PortScanner.procAddress("00000000000000000000000000000000", v6: true), "::")
        XCTAssertEqual(PortScanner.procAddress("0000000000000000FFFF00000100007F", v6: true), "127.0.0.1")
    }
    #endif

    // MARK: Forwarder

    func testAPortTakenOnThisMacIsReportedNotMoved() async throws {
        let hello = try await hello()
        let (listener, port) = try Self.listenAnyPort()
        defer { _ = close(listener) }
        let forwarder = Self.manualForwarder()
        forwarder.connected(client, hello)
        forwarder.forward(port)
        XCTAssertEqual(forwarder.entries.first { $0.port == port }?.state, .failed("In use on this Mac"))
        XCTAssertFalse(forwarder.forwardedPorts.contains(port))
        forwarder.stop()
    }

    func testForwarderServesTheRemotePortOnLocalhost() async throws {
        let hello = try await hello()
        // The "remote" dev server sits on another port; the engine side
        // maps the forwarded port there, as a remote machine would reach
        // its own loopback.
        let (devServer, devPort) = try Self.listenAnyPort()
        defer { _ = close(devServer) }
        let (probe, port) = try Self.listenAnyPort()
        _ = close(probe)
        Self.farEnd[port] = devPort
        let served = Self.background {
            let fd = accept(devServer, nil, nil)
            guard fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(fd, &buffer, buffer.count)
            _ = writeAll(fd: fd, Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8))
            _ = close(fd)
        }
        let forwarder = Self.manualForwarder()
        forwarder.connected(client, hello)
        forwarder.forward(port)
        await eventually("forwarding", timeout: 8) { forwarder.forwardedPorts == [port] }
        XCTAssertEqual(forwarder.entries.first?.state, .forwarding)

        let fd = jl_tcp_connect("127.0.0.1", Int32(port), 2000)
        guard fd >= 0 else {
            XCTFail("couldn't connect to the forwarded port: \(fd)")
            // Wake the dev server's accept (close alone doesn't, on Linux).
            _ = shutdown(devServer, Int32(SHUT_RDWR))
            await served.value
            return
        }
        _ = writeAll(fd: fd, Data("GET / HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n".utf8))
        let received = await Self.readToEnd(fd)
        _ = close(fd)
        await served.value
        XCTAssertTrue(String(decoding: received, as: UTF8.self).hasSuffix("\r\n\r\nok"), String(decoding: received, as: UTF8.self))

        forwarder.stopForwarding(port)
        XCTAssertEqual(forwarder.forwardedPorts, [])
        await eventually("the listener to go", timeout: 2) { !Self.accepts(port) }
        forwarder.stop()
    }

    func testForwarderSkipsAnEngineOnThisSameMachine() async throws {
        let hello = try await hello()
        let forwarder = PortForwarder(hostId: "test", hostName: "devbox", persists: false)
        forwarder.connected(client, hello)
        XCTAssertTrue(forwarder.isSameMachine)
        forwarder.received([ListeningPort(port: 23456, addresses: ["127.0.0.1"], process: nil, suggested: true)])
        XCTAssertEqual(forwarder.forwardedPorts, [])
        forwarder.stop()
    }

    func testForwarderFollowsSuggestedPortsAndRespectsOptOut() async throws {
        let forwarder = Self.manualForwarder()
        let hello = try await hello()
        forwarder.connected(client, hello)
        // Let the forwarder's own ports.watch reply (this machine's real
        // list) land first, and only then turn automatic forwarding on,
        // for the stand-in list.
        await forwarder.initialWatch?.value
        let (probe, port) = try Self.listenAnyPort()
        _ = close(probe)
        forwarder.received([ListeningPort(port: port, addresses: ["127.0.0.1"], process: "node", suggested: true)])
        forwarder.forwardsAutomatically = true
        await eventually("forwarding", timeout: 8) { forwarder.forwardedPorts == [port] }
        XCTAssertEqual(forwarder.entries.map(\.process), ["node"])

        forwarder.stopForwarding(port)
        XCTAssertEqual(forwarder.forwardedPorts, [])
        XCTAssertEqual(forwarder.entries.first?.state, .off)

        forwarder.forward(port)
        // At once, or on the quick retry if the old socket lingered.
        await eventually("forwarding again", timeout: 8) { forwarder.forwardedPorts == [port] }

        // The server stops: an automatic forward goes with it.
        forwarder.received([])
        XCTAssertEqual(forwarder.forwardedPorts, [])
        XCTAssertTrue(forwarder.entries.isEmpty)
        forwarder.stop()
    }

    // MARK: Helpers


    /// With app and engine on one machine, automatic forwarding would try
    /// this machine's own listeners; tests forward only what they ask for.
    private static func manualForwarder() -> PortForwarder {
        let forwarder = PortForwarder(hostId: "test", hostName: "devbox", persists: false, allowsSameMachine: true)
        forwarder.forwardsAutomatically = false
        return forwarder
    }

    private static func accepts(_ port: Int) -> Bool {
        let fd = jl_tcp_connect("127.0.0.1", Int32(port), 2000)
        guard fd >= 0 else { return false }
        _ = close(fd)
        return true
    }

    /// A listening socket on 127.0.0.1 and its port.
    private static func listenAnyPort(inRange range: Range<Int>? = nil) throws -> (Int32, Int) {
        for _ in 0..<50 {
            let candidate = range.map { Int.random(in: $0) } ?? Int.random(in: 20000..<30000)
            let fd = jl_tcp_listen_loopback(4, Int32(candidate), 0)
            if fd >= 0 { return (fd, candidate) }
        }
        throw XCTSkip("no free port")
    }

    /// On its own thread: these block, and the cooperative pool may have
    /// only a couple.
    private static func background<T: Sendable>(_ body: @escaping @Sendable () -> T) -> Task<T, Never> {
        Task {
            await withCheckedContinuation { continuation in
                Thread { continuation.resume(returning: body()) }.start()
            }
        }
    }

    /// Until EOF, or 20 s of silence (a hang fails rather than stalls the run).
    private static func readToEnd(_ fd: Int32) async -> Data {
        await background {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 20_000) > 0 else { return data }
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
}
