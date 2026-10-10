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
        _ = TestSupport.dataDir
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
        (server, client) = try TestSupport.engineAndClient(tunnelConnect: { port in
            let target = PortForwardingTests.farEnd[port] ?? port
            let fd = jl_tcp_connect("127.0.0.1", Int32(target), 2000)
            return fd >= 0 ? fd : nil
        }) { [weak self] event in self?.events.append(event) }
    }

    override func tearDown() async throws {
        client.close()
        await server.engine.shutdown()
    }

    private func hello() async throws -> API.HelloResult {
        try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "test"))
    }

    // MARK: Tunnels

    func testForwardedConnectionCarriesBytesBothWaysAndHalfCloses() async throws {
        let hello = try await hello()
        XCTAssertEqual(hello.features, API.features)
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

    func testAnEngineWithoutTunnelsForwardsNothing() async throws {
        var hello = try await hello()
        hello.features = nil
        let forwarder = Self.manualForwarder()
        forwarder.connected(client, hello)
        XCTAssertFalse(forwarder.isSupported)
        let (probe, port) = try Self.listenAnyPort()
        _ = close(probe)
        forwarder.forward(port)
        XCTAssertEqual(forwarder.forwardedPorts, [], "nothing to carry the connections")
        forwarder.stop()
    }

    func testTheSameMachineListsNoEntries() async throws {
        let hello = try await hello()
        let forwarder = PortForwarder(hostId: "test", hostName: "devbox", persists: false)
        forwarder.connected(client, hello)
        forwarder.forward(40123)
        XCTAssertTrue(forwarder.entries.isEmpty, "the sidebar shows nothing to forward")
        XCTAssertEqual(forwarder.forwardedPorts, [])
        forwarder.stop()
    }

    func testOnlySuggestedPortsAreForwardedAutomatically() async throws {
        let forwarder = Self.manualForwarder()
        let hello = try await hello()
        forwarder.connected(client, hello)
        await forwarder.initialWatch?.value
        let (p1, suggested) = try Self.listenAnyPort()
        let (p2, other) = try Self.listenAnyPort()
        _ = close(p1)
        _ = close(p2)
        forwarder.received([
            ListeningPort(port: suggested, addresses: ["127.0.0.1"], process: "vite", suggested: true),
            ListeningPort(port: other, addresses: ["0.0.0.0"], process: "sshd", suggested: false),
        ])
        forwarder.forwardsAutomatically = true
        await eventually("suggested one forwarded", timeout: 8) { forwarder.forwardedPorts == [suggested] }
        XCTAssertEqual(forwarder.entries.map(\.port), [suggested])
        XCTAssertEqual(forwarder.otherPorts.map(\.port), [other], "the rest is offered, not forwarded")

        // Forwarding one by hand keeps it, even once it stops listening.
        forwarder.forward(other)
        await eventually("both", timeout: 8) { Set(forwarder.forwardedPorts) == [suggested, other] }
        forwarder.received([ListeningPort(port: suggested, addresses: ["127.0.0.1"], process: "vite", suggested: true)])
        XCTAssertEqual(Set(forwarder.forwardedPorts), [suggested, other])
        XCTAssertEqual(forwarder.entries.first { $0.port == other }?.isListening, false)
        XCTAssertEqual(forwarder.entries.first { $0.port == suggested }?.isListening, true)

        // Turning automatic off keeps the manual one only.
        forwarder.forwardsAutomatically = false
        XCTAssertEqual(forwarder.forwardedPorts, [other])
        forwarder.stop()
        XCTAssertEqual(forwarder.forwardedPorts, [])
    }

    func testTwoRemotesWantingOnePortTakeTurns() async throws {
        let hello = try await hello()
        let (probe, port) = try Self.listenAnyPort()
        _ = close(probe)
        let first = PortForwarder(hostId: "a", hostName: "alpha", persists: false, allowsSameMachine: true)
        let second = PortForwarder(hostId: "b", hostName: "beta", persists: false, allowsSameMachine: true)
        for forwarder in [first, second] {
            forwarder.forwardsAutomatically = false
            forwarder.connected(client, hello)
        }
        first.forward(port)
        await eventually("first has it", timeout: 8) { first.forwardedPorts == [port] }
        second.forward(port)
        XCTAssertEqual(second.entries.first?.state, .failed("Forwarded from alpha"))
        XCTAssertEqual(second.forwardedPorts, [])

        // Let go: the one waiting takes it over.
        first.stopForwarding(port)
        await eventually("second takes over", timeout: 8) { second.forwardedPorts == [port] }
        XCTAssertEqual(second.entries.first?.state, .forwarding)
        first.stop()
        second.stop()
    }

    func testWhileTheLinkIsDownConnectionsAreRefusedButThePortIsKept() async throws {
        let hello = try await hello()
        let (probe, port) = try Self.listenAnyPort()
        _ = close(probe)
        let forwarder = Self.manualForwarder()
        forwarder.connected(client, hello)
        forwarder.forward(port)
        await eventually("forwarding", timeout: 8) { forwarder.forwardedPorts == [port] }
        forwarder.disconnected()
        XCTAssertEqual(forwarder.forwardedPorts, [port], "still bound, so nothing else grabs it")
        let fd = jl_tcp_connect("127.0.0.1", Int32(port), 2000)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 {
            let reply = await TestIO.readToEnd(fd, silence: 5)
            XCTAssertTrue(reply.isEmpty, "closed at once rather than left hanging")
            _ = close(fd)
        }
        forwarder.stop()
    }

    // MARK: Listener and scanner

    func testALoopbackListenerReportsATakenPortAndFreesItsOwn() async throws {
        let (taken, port) = try Self.listenAnyPort()
        XCTAssertThrowsError(try LoopbackListener(port: port) { _ in }) { error in
            XCTAssertEqual(error as? LoopbackListener.Failure, .inUse)
            XCTAssertEqual((error as? LoopbackListener.Failure)?.message, "In use on this Mac")
        }
        _ = close(taken)

        let accepted = Locked(0)
        let listener = try await Self.bindSoon(port) { fd in
            accepted.mutate { $0 += 1 }
            Glibc_or_Darwin_close(fd)
        }
        let fd = jl_tcp_connect("127.0.0.1", Int32(port), 2000)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { _ = close(fd) }
        await eventually("accepted") { accepted.value == 1 }
        listener.close()
        XCTAssertFalse(Self.accepts(port))
        // Bindable again, TIME_WAIT from the accepted connection or not.
        let again = try await Self.bindSoon(port) { fd in Glibc_or_Darwin_close(fd) }
        again.close()
    }

    /// A closed listener can linger for a moment in a subprocess forked
    /// just then (until its exec); other tests' engines spawn plenty.
    private static func bindSoon(_ port: Int, onAccept: @escaping @Sendable (Int32) -> Void) async throws -> LoopbackListener {
        let deadline = Date().addingTimeInterval(2)
        while true {
            do {
                return try LoopbackListener(port: port, onAccept: onAccept)
            } catch {
                // Not `catch where`: Swift 6.3 crashes in SILGen on it here.
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func testConnectTargetsFollowWhereTheServerListens() throws {
        let scanner = PortScanner()
        // Unknown ports: loopback, both families.
        XCTAssertEqual(scanner.connectTargets(for: 1), ["127.0.0.1", "::1"])

        let v6 = jl_tcp_listen_loopback(6, 0, 0)
        try XCTSkipIf(v6 < 0, "no IPv6 loopback")
        defer { _ = close(v6) }
        var addr = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(v6, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin6_port))
        let found = scanner.scanNow().first { $0.port == port }
        XCTAssertEqual(found?.addresses, ["::1"])
        XCTAssertEqual(scanner.connectTargets(for: port), ["::1", "127.0.0.1"], "where it listens first")
    }

    func testScannerReportsChangesOnlyWhenTheListChanges() async throws {
        let scanner = PortScanner(interval: .milliseconds(100))
        let reports = Locked<[[ListeningPort]]>([])
        scanner.onChange = { ports in reports.mutate { $0.append(ports) } }
        scanner.start()
        defer { scanner.stop() }
        await eventually("first scan", timeout: 10) { !reports.value.isEmpty }
        let (listener, port) = try Self.listenAnyPort(inRange: 20000..<29000)
        await eventually("new port reported", timeout: 15) { reports.value.last?.contains { $0.port == port } == true }
        let count = reports.value.count
        try await Task.sleep(for: .milliseconds(400))
        // Other processes may come and go; this port's entry mustn't repeat.
        XCTAssertLessThanOrEqual(reports.value.count - count, 2)
        _ = close(listener)
        await eventually("port gone", timeout: 15) { reports.value.last?.contains { $0.port == port } == false }
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
