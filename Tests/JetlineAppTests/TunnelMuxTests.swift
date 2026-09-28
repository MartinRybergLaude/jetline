import XCTest
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

/// `TunnelMux` on its own: frame by frame against a recorded peer, and two
/// muxes wired back to back with socketpairs standing in for the browser
/// and the dev server.
@MainActor
final class TunnelMuxTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    private struct Sent: Sendable {
        var kind: FrameKind
        var payload: Data
        var stream: UInt32 { payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
        var body: Data { payload.dropFirst(4) }
    }

    private var muxes: [TunnelMux] = []
    private var fds: [Int32] = []

    override func tearDown() async throws {
        for mux in muxes { mux.close() }
        try await Task.sleep(for: .milliseconds(50))
        for fd in fds { _ = close(fd) }
        muxes = []
        fds = []
    }

    /// A mux whose outgoing frames are only recorded.
    private func recordingMux(connect: (@Sendable (Int) -> Int32?)? = nil) -> (TunnelMux, Locked<[Sent]>) {
        let sent = Locked<[Sent]>([])
        let mux = TunnelMux(label: "rec", connect: connect) { kind, payload in
            sent.mutate { $0.append(Sent(kind: kind, payload: payload)) }
        }
        muxes.append(mux)
        return (mux, sent)
    }

    private func pair() throws -> (Int32, Int32) {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        fds.append(a)
        return (a, b)
    }

    /// Close a test-held end early (tearDown would close it again, maybe
    /// after its number was reused).
    private func closeTracked(_ fd: Int32) {
        fds.removeAll { $0 == fd }
        _ = close(fd)
    }

    private static func header(_ id: UInt32) -> Data {
        withUnsafeBytes(of: id.bigEndian) { Data($0) }
    }

    private static func ack(_ id: UInt32, _ count: UInt32) -> Data {
        header(id) + withUnsafeBytes(of: count.bigEndian) { Data($0) }
    }

    private func frames(_ sent: Locked<[Sent]>, _ kind: FrameKind) -> [Sent] {
        sent.value.filter { $0.kind == kind }
    }

    // MARK: Client side, frame by frame

    func testOpenAnnouncesTheStreamAndPort() async throws {
        let (mux, sent) = recordingMux()
        let (_, first) = try pair()
        let (_, second) = try pair()
        mux.open(fd: first, port: 3000)
        mux.open(fd: second, port: 65535)
        await eventually("two opens") { frames(sent, .tunnelOpen).count == 2 }
        let opens = frames(sent, .tunnelOpen)
        XCTAssertEqual(opens.map(\.stream), [1, 2], "stream ids count up")
        XCTAssertEqual(opens[0].body, Data([0x0B, 0xB8]))
        XCTAssertEqual(opens[1].body, Data([0xFF, 0xFF]))
        XCTAssertEqual(mux.openStreamCount, 2)
    }

    func testLocalBytesBecomeDataFramesAndPeerBytesAreWritten() async throws {
        let (mux, sent) = recordingMux()
        let (browser, app) = try pair()
        mux.open(fd: app, port: 8080)
        XCTAssertNil(writeAll(fd: browser, Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        await eventually("data frame") { frames(sent, .tunnelData).reduce(0) { $0 + $1.body.count } == 18 }
        XCTAssertEqual(frames(sent, .tunnelData).map(\.body).reduce(Data(), +), Data("GET / HTTP/1.1\r\n\r\n".utf8))

        mux.receive(.tunnelData, Self.header(1) + Data("HTTP/1.1 200 OK\r\n".utf8))
        XCTAssertEqual(String(decoding: TestIO.readExactly(browser, count: 17), as: UTF8.self), "HTTP/1.1 200 OK\r\n")
        // Written bytes are acknowledged to the peer.
        await eventually("ack") { frames(sent, .tunnelAck).contains { $0.stream == 1 } }
        let acked = frames(sent, .tunnelAck).map { $0.body.reduce(0) { $0 << 8 | Int($1) } }.reduce(0, +)
        XCTAssertEqual(acked, 17)
    }

    func testLocalEOFIsAHalfCloseAndThePeerCanStillAnswer() async throws {
        let (mux, sent) = recordingMux()
        let (browser, app) = try pair()
        mux.open(fd: app, port: 8080)
        XCTAssertNil(writeAll(fd: browser, Data("req".utf8)))
        _ = shutdown(browser, Int32(SHUT_WR))
        await eventually("half close") { frames(sent, .tunnelClose).contains { $0.body == Data([0]) } }
        XCTAssertEqual(mux.openStreamCount, 1, "still open for the answer")

        mux.receive(.tunnelData, Self.header(1) + Data("answer".utf8))
        mux.receive(.tunnelClose, Self.header(1) + Data([0]))
        let reply = await TestIO.readToEnd(browser, silence: 5)
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "answer", "data, then EOF")
        await eventually("stream done") { mux.openStreamCount == 0 }
        XCTAssertFalse(frames(sent, .tunnelClose).contains { $0.body == Data([1]) }, "a clean finish isn't a reset")
    }

    func testPeerResetDropsTheStreamAtOnce() async throws {
        let (mux, _) = recordingMux()
        let (browser, app) = try pair()
        mux.open(fd: app, port: 8080)
        await eventually("open") { mux.openStreamCount == 1 }
        mux.receive(.tunnelClose, Self.header(1) + Data([1]))
        await eventually("gone") { mux.openStreamCount == 0 }
        let rest = await TestIO.readToEnd(browser, silence: 5)
        XCTAssertTrue(rest.isEmpty)
    }

    func testCloseResetsEveryStreamAndRefusesNewOnes() async throws {
        let (mux, _) = recordingMux()
        let (b1, a1) = try pair()
        let (b2, a2) = try pair()
        mux.open(fd: a1, port: 1)
        mux.open(fd: a2, port: 2)
        await eventually("open") { mux.openStreamCount == 2 }
        mux.close()
        await eventually("all gone") { mux.openStreamCount == 0 }
        let r1 = await TestIO.readToEnd(b1, silence: 5)
        let r2 = await TestIO.readToEnd(b2, silence: 5)
        XCTAssertTrue(r1.isEmpty && r2.isEmpty)

        let (b3, a3) = try pair()
        mux.open(fd: a3, port: 3)
        let r3 = await TestIO.readToEnd(b3, silence: 5)
        XCTAssertTrue(r3.isEmpty, "a connection after close is closed straight away")
        XCTAssertEqual(mux.openStreamCount, 0)
    }

    func testMalformedAndUnknownFramesAreIgnored() async throws {
        let (mux, sent) = recordingMux()
        let (browser, app) = try pair()
        mux.open(fd: app, port: 80)
        await eventually("open") { mux.openStreamCount == 1 }
        mux.receive(.tunnelData, Data([0, 0]))            // too short for a stream id
        mux.receive(.tunnelAck, Self.header(1) + Data([1])) // too short for a count
        mux.receive(.tunnelData, Self.header(99) + Data("x".utf8)) // unknown stream
        mux.receive(.tunnelClose, Self.header(99) + Data([1]))
        mux.receive(.message, Self.header(1))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(mux.openStreamCount, 1)
        mux.receive(.tunnelData, Self.header(1) + Data("ok".utf8))
        XCTAssertEqual(TestIO.readExactly(browser, count: 2), Data("ok".utf8))
        XCTAssertFalse(frames(sent, .tunnelClose).contains { $0.stream == 1 })
    }

    // MARK: Engine side, frame by frame

    func testOpenWithoutAConnectorOrPortIsRefused() async throws {
        let (clientOnly, sent) = recordingMux()
        clientOnly.receive(.tunnelOpen, Self.header(5) + Data([0x1F, 0x90]))
        await eventually("reset") { frames(sent, .tunnelClose).first.map { $0.stream == 5 && $0.body == Data([1]) } == true }

        let (engine, engineSent) = recordingMux { _ in XCTFail("port 0 must not connect"); return nil }
        engine.receive(.tunnelOpen, Self.header(6) + Data([0, 0]))
        engine.receive(.tunnelOpen, Self.header(7))
        await eventually("resets") { frames(engineSent, .tunnelClose).map(\.stream).sorted() == [6, 7] }
    }

    func testAFailedConnectIsAReset() async throws {
        let ports = Locked<[Int]>([])
        let (mux, sent) = recordingMux { port in ports.mutate { $0.append(port) }; return nil }
        mux.receive(.tunnelOpen, Self.header(1) + Data([0x0B, 0xB8]))
        await eventually("reset") { frames(sent, .tunnelClose).contains { $0.stream == 1 && $0.body == Data([1]) } }
        XCTAssertEqual(ports.value, [3000])
        XCTAssertEqual(mux.openStreamCount, 0)
    }

    func testDataSentWhileConnectingIsHeldAndDelivered() async throws {
        let (server, far) = try pair()
        let gate = DispatchSemaphore(value: 0)
        let (mux, _) = recordingMux { _ in
            gate.wait()
            return far
        }
        mux.receive(.tunnelOpen, Self.header(1) + Data([0, 80]))
        mux.receive(.tunnelData, Self.header(1) + Data("early ".utf8))
        mux.receive(.tunnelData, Self.header(1) + Data("bytes".utf8))
        mux.receive(.tunnelClose, Self.header(1) + Data([0]))
        try await Task.sleep(for: .milliseconds(50))
        gate.signal()
        let received = await TestIO.readToEnd(server, silence: 5)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "early bytes", "in order, then EOF")
    }

    func testAResetWhileConnectingClosesTheNewSocket() async throws {
        let (server, far) = try pair()
        let gate = DispatchSemaphore(value: 0)
        let (mux, sent) = recordingMux { _ in
            gate.wait()
            return far
        }
        mux.receive(.tunnelOpen, Self.header(1) + Data([0, 80]))
        mux.receive(.tunnelClose, Self.header(1) + Data([1]))
        try await Task.sleep(for: .milliseconds(50))
        gate.signal()
        let received = await TestIO.readToEnd(server, silence: 5)
        XCTAssertTrue(received.isEmpty, "the socket is closed, not adopted")
        XCTAssertEqual(mux.openStreamCount, 0)
        await eventually("reset back") { frames(sent, .tunnelClose).contains { $0.stream == 1 } }
    }

    func testADuplicateOpenIsRefused() async throws {
        let (_, far) = try pair()
        let (mux, sent) = recordingMux { _ in far }
        mux.receive(.tunnelOpen, Self.header(1) + Data([0, 80]))
        await eventually("adopted") { mux.openStreamCount == 1 }
        mux.receive(.tunnelOpen, Self.header(1) + Data([0, 80]))
        await eventually("refused") { frames(sent, .tunnelClose).contains { $0.stream == 1 && $0.body == Data([1]) } }
    }

    // MARK: Back to back

    /// Client and engine muxes joined directly; `delivered` observes every
    /// frame in both directions.
    private final class Link: @unchecked Sendable {
        var client: TunnelMux!
        var engine: TunnelMux!
        let clientToEngineData = Locked(0)
        let engineToClientAcks = Locked(0)
        let maxInFlight = Locked(0)
    }

    private func link(connect: @escaping @Sendable (Int) -> Int32?) -> Link {
        let link = Link()
        link.engine = TunnelMux(label: "engine", connect: connect) { [weak link] kind, payload in
            guard let link else { return }
            if kind == .tunnelAck {
                let count = payload.dropFirst(4).reduce(0) { $0 << 8 | Int($1) }
                link.engineToClientAcks.mutate { $0 += count }
            }
            link.client.receive(kind, payload)
        }
        link.client = TunnelMux(label: "client") { [weak link] kind, payload in
            guard let link else { return }
            if kind == .tunnelData {
                let sent = link.clientToEngineData.mutate { $0 += payload.count - 4; return $0 }
                let inFlight = sent - link.engineToClientAcks.value
                link.maxInFlight.mutate { $0 = max($0, inFlight) }
            }
            link.engine.receive(kind, payload)
        }
        muxes += [link.client, link.engine]
        return link
    }

    func testEchoThroughTwoMuxes() async throws {
        let (devServer, far) = try pair()
        let link = link { _ in far }
        let echo = TestIO.background {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(devServer, &buffer, buffer.count)
                if n <= 0 { break }
                _ = buffer.withUnsafeBytes { writeAll(fd: devServer, $0.baseAddress!, count: n) }
            }
            _ = shutdown(devServer, Int32(SHUT_WR))
        }
        let (browser, app) = try pair()
        link.client.open(fd: app, port: 3000)
        var payload = Data(count: 3 * TunnelMux.window + 999)
        for i in payload.indices { payload[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
        let sent = payload
        let writer = TestIO.background {
            _ = writeAll(fd: browser, sent)
            _ = shutdown(browser, Int32(SHUT_WR))
        }
        let received = await TestIO.readToEnd(browser)
        await writer.value
        await echo.value
        XCTAssertEqual(received.count, payload.count)
        XCTAssertTrue(received == payload)
        await eventually("both sides done") { link.client.openStreamCount == 0 && link.engine.openStreamCount == 0 }
    }

    /// A dev server that stops reading must stall the upload at one window,
    /// not buffer it all.
    func testASlowReceiverHoldsTheSenderToOneWindow() async throws {
        let (devServer, far) = try pair()
        let link = link { _ in far }
        let (browser, app) = try pair()
        link.client.open(fd: app, port: 3000)
        let total = 6 * TunnelMux.window
        let payload = Data(repeating: 0x5A, count: total)
        let writer = TestIO.background {
            _ = writeAll(fd: browser, payload)
            _ = shutdown(browser, Int32(SHUT_WR))
        }
        // Let it fill up.
        try await Task.sleep(for: .milliseconds(700))
        let stalledAt = link.clientToEngineData.value
        XCTAssertLessThan(stalledAt, total, "the transfer should stall while nobody reads")
        XCTAssertLessThanOrEqual(link.maxInFlight.value, TunnelMux.window)

        // Now drain it: everything arrives, still within the window.
        let received = await TestIO.readToEnd(devServer, silence: 10)
        await writer.value
        XCTAssertEqual(received.count, total)
        XCTAssertLessThanOrEqual(link.maxInFlight.value, TunnelMux.window)
        closeTracked(devServer)
    }

    func testADevServerThatClosesEndsTheBrowsersConnection() async throws {
        let (devServer, far) = try pair()
        let link = link { _ in far }
        let (browser, app) = try pair()
        link.client.open(fd: app, port: 3000)
        await eventually("connected") { link.engine.openStreamCount == 1 }
        XCTAssertNil(writeAll(fd: devServer, Data("bye".utf8)))
        closeTracked(devServer)
        let received = await TestIO.readToEnd(browser, silence: 5)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "bye")
        _ = shutdown(browser, Int32(SHUT_WR))
        await eventually("both sides done") { link.client.openStreamCount == 0 && link.engine.openStreamCount == 0 }
    }

    func testManyConcurrentStreamsStaySeparate() async throws {
        let servers = Locked<[Int32]>([])
        let link = link { _ in
            guard let (a, b) = Sockets.pair() else { return nil }
            servers.mutate { $0.append(a) }
            // Each dev-server connection answers with what it got, reversed.
            Thread {
                var got = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(a, &buffer, buffer.count)
                    if n <= 0 { break }
                    got.append(contentsOf: buffer[0..<n])
                }
                _ = writeAll(fd: a, Data(got.reversed()))
                _ = close(a)
            }.start()
            return b
        }
        var browsers: [(Int32, String)] = []
        for i in 0..<20 {
            let (browser, app) = try pair()
            link.client.open(fd: app, port: 4000 + i)
            browsers.append((browser, "stream-\(i)-" + String(repeating: "\(i % 10)", count: i * 100)))
        }
        for (fd, message) in browsers {
            XCTAssertNil(writeAll(fd: fd, Data(message.utf8)))
            _ = shutdown(fd, Int32(SHUT_WR))
        }
        for (fd, message) in browsers {
            let reply = await TestIO.readToEnd(fd, silence: 10)
            XCTAssertEqual(String(decoding: reply, as: UTF8.self), String(message.reversed()))
        }
        await eventually("all done") { link.client.openStreamCount == 0 && link.engine.openStreamCount == 0 }
    }
}
