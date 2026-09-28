import XCTest
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

/// The byte-level protocol: `FramedConnection` framing over a real
/// socketpair, the terminal frame codecs, JSON envelopes and the socket
/// helpers.
@MainActor
final class WireFramingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
        _ = TestSupport.dataDir
    }

    /// A connection on one end of a socketpair; the test drives the raw
    /// other end.
    private struct Harness {
        let connection: FramedConnection
        let peer: Int32
        let frames: Locked<[FramedConnection.Frame]>
        let closes: Locked<Int>
    }

    private var openFDs: [Int32] = []
    private var connections: [FramedConnection] = []

    override func tearDown() async throws {
        for connection in connections { connection.close() }
        for fd in openFDs { _ = close(fd) }
        connections = []
        openFDs = []
    }

    private func harness(preamble: Data? = nil) throws -> Harness {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        let connection = FramedConnection(readFD: a, writeFD: a, label: "wire-test", preamble: preamble)
        let frames = Locked<[FramedConnection.Frame]>([])
        let closes = Locked(0)
        connection.onFrames = { batch in frames.mutate { $0 += batch } }
        connection.onClose = { closes.mutate { $0 += 1 } }
        connection.start()
        connections.append(connection)
        openFDs.append(b)
        return Harness(connection: connection, peer: b, frames: frames, closes: closes)
    }

    private func write(_ fd: Int32, _ data: Data) {
        XCTAssertNil(writeAll(fd: fd, data))
    }

    // MARK: FramedConnection — reading

    func testFramesSplitAcrossManyReadsAreReassembled() async throws {
        let h = try harness()
        let bytes = TestIO.frame(json: #"{"hello":"world"}"#) + TestIO.frame(.terminalInput, Data([1, 2, 3]))
        // One byte at a time, so every length prefix and payload straddles reads.
        for byte in bytes {
            write(h.peer, Data([byte]))
            usleep(200)
        }
        await eventually("both frames") { h.frames.value.count == 2 }
        let frames = h.frames.value
        XCTAssertEqual(frames[0].kind, .message)
        XCTAssertEqual(String(decoding: frames[0].payload, as: UTF8.self), #"{"hello":"world"}"#)
        XCTAssertEqual(frames[1].kind, .terminalInput)
        XCTAssertEqual(frames[1].payload, Data([1, 2, 3]))
        XCTAssertEqual(h.closes.value, 0)
    }

    func testManyFramesInOneWriteArriveInOrder() async throws {
        let h = try harness()
        var bytes = Data()
        for i in 0..<2000 { bytes += TestIO.frame(json: "\(i)") }
        let peer = h.peer
        let sent = bytes
        await TestIO.background { _ = writeAll(fd: peer, sent) }.value
        await eventually("all frames") { h.frames.value.count == 2000 }
        let numbers = h.frames.value.map { Int(String(decoding: $0.payload, as: UTF8.self)) }
        XCTAssertEqual(numbers, Array(0..<2000))
    }

    func testFrameLargerThanTheReadBufferArrivesWhole() async throws {
        let h = try harness()
        var payload = Data(count: 3 * 1024 * 1024 + 17)
        for i in payload.indices { payload[i] = UInt8(truncatingIfNeeded: i &* 131) }
        let bytes = TestIO.frame(.tunnelData, payload)
        let peer = h.peer
        await TestIO.background { _ = writeAll(fd: peer, bytes) }.value
        await eventually("the big frame", timeout: 15) { h.frames.value.count == 1 }
        XCTAssertEqual(h.frames.value.first?.kind, .tunnelData)
        XCTAssertTrue(h.frames.value.first?.payload == payload)
    }

    func testEmptyPayloadIsAValidFrame() async throws {
        let h = try harness()
        write(h.peer, TestIO.frame(.terminalInput, Data()))
        await eventually("empty frame") { h.frames.value.count == 1 }
        XCTAssertEqual(h.frames.value.first?.payload, Data())
    }

    func testUnknownFrameKindsAreSkippedNotFatal() async throws {
        let h = try harness()
        write(h.peer, TestIO.frame(json: "a") + TestIO.frame(kind: 200, Data("ignored".utf8)) + TestIO.frame(json: "b"))
        await eventually("known frames") { h.frames.value.count == 2 }
        XCTAssertEqual(h.frames.value.map { String(decoding: $0.payload, as: UTF8.self) }, ["a", "b"])
        XCTAssertEqual(h.closes.value, 0)
        XCTAssertFalse(h.connection.isClosed)
    }

    func testZeroLengthFrameClosesTheConnection() async throws {
        let h = try harness()
        write(h.peer, TestIO.frame(json: "before") + Data([0, 0, 0, 0]) + TestIO.frame(json: "after"))
        await eventually("close") { h.closes.value == 1 }
        XCTAssertTrue(h.connection.isClosed)
        XCTAssertEqual(h.frames.value.map { String(decoding: $0.payload, as: UTF8.self) }, ["before"])
    }

    func testOversizedLengthClosesTheConnection() async throws {
        let h = try harness()
        var length = UInt32(FramedConnection.maxFrameLength + 1).bigEndian
        var bytes = Data()
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(FrameKind.message.rawValue)
        write(h.peer, bytes)
        await eventually("close") { h.closes.value == 1 }
        XCTAssertTrue(h.frames.value.isEmpty)
    }

    func testPeerHangupClosesOnceAndClosesTheFD() async throws {
        let h = try harness()
        write(h.peer, TestIO.frame(json: "last words"))
        _ = shutdown(h.peer, Int32(SHUT_WR))
        await eventually("close") { h.closes.value == 1 }
        XCTAssertEqual(h.frames.value.count, 1, "a frame before EOF is still delivered")
        // Our end is closed: the peer reads EOF.
        let rest = await TestIO.readToEnd(h.peer, silence: 5)
        XCTAssertTrue(rest.isEmpty)
        h.connection.close()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.closes.value, 1, "onClose fires once")
    }

    func testPartialFrameAtEOFIsDropped() async throws {
        let h = try harness()
        let full = TestIO.frame(json: "complete")
        write(h.peer, full + TestIO.frame(json: "cut off").prefix(6))
        _ = shutdown(h.peer, Int32(SHUT_WR))
        await eventually("close") { h.closes.value == 1 }
        XCTAssertEqual(h.frames.value.count, 1)
    }

    // MARK: FramedConnection — preamble

    func testPreambleSkipsWhateverALoginScriptPrinted() async throws {
        let h = try harness(preamble: AttachPreamble.marker)
        let banner = Data("Welcome to devbox!\nLast login: yesterday\n".utf8)
        // A frame-shaped banner would be misread without the marker.
        write(h.peer, banner + TestIO.frame(json: "decoy") + AttachPreamble.marker.prefix(5))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(h.frames.value.isEmpty, "nothing before the marker is a frame")
        // The rest of the marker, split across a read, then real frames.
        write(h.peer, AttachPreamble.marker.dropFirst(5) + TestIO.frame(json: "one") + TestIO.frame(json: "two"))
        await eventually("frames after the marker") { h.frames.value.count == 2 }
        XCTAssertEqual(h.frames.value.map { String(decoding: $0.payload, as: UTF8.self) }, ["one", "two"])
    }

    func testPreambleFollowedByFramesInTheSameRead() async throws {
        let h = try harness(preamble: AttachPreamble.marker)
        write(h.peer, AttachPreamble.marker + TestIO.frame(json: "x"))
        await eventually("frame") { h.frames.value.count == 1 }
    }

    func testAPeerThatNeverSendsThePreambleIsDropped() async throws {
        let h = try harness(preamble: AttachPreamble.marker)
        write(h.peer, Data("bash: jetlined: command not found\n".utf8))
        _ = shutdown(h.peer, Int32(SHUT_WR))
        await eventually("close") { h.closes.value == 1 }
        XCTAssertTrue(h.frames.value.isEmpty)
    }

    // MARK: FramedConnection — writing

    func testTwoConnectionsExchangeFramesBothWays() async throws {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        let left = FramedConnection(readFD: a, writeFD: a, label: "left")
        let right = FramedConnection(readFD: b, writeFD: b, label: "right")
        connections += [left, right]
        let leftGot = Locked<[FramedConnection.Frame]>([])
        let rightGot = Locked<[FramedConnection.Frame]>([])
        left.onFrames = { f in leftGot.mutate { $0 += f } }
        right.onFrames = { f in rightGot.mutate { $0 += f } }
        left.start()
        right.start()
        for i in 0..<100 {
            left.send(.message, Data("L\(i)".utf8))
            right.send(.terminalOutput, Data("R\(i)".utf8))
        }
        await eventually("both directions") { leftGot.value.count == 100 && rightGot.value.count == 100 }
        XCTAssertEqual(rightGot.value.map { String(decoding: $0.payload, as: UTF8.self) }, (0..<100).map { "L\($0)" })
        XCTAssertTrue(leftGot.value.allSatisfy { $0.kind == .terminalOutput })
        await eventually("writes drained") { left.pendingWriteBytes == 0 && right.pendingWriteBytes == 0 }
    }

    func testSendAfterCloseIsDropped() async throws {
        let h = try harness()
        h.connection.close()
        await eventually("closed") { h.connection.isClosed }
        h.connection.send(.message, Data("too late".utf8))
        XCTAssertEqual(h.connection.pendingWriteBytes, 0)
        let bytes = await TestIO.readToEnd(h.peer, silence: 5)
        XCTAssertTrue(bytes.isEmpty)
    }

    func testCloseLetsQueuedWritesGoOutFirst() async throws {
        let h = try harness()
        let payload = Data(repeating: 0xAB, count: 2 * 1024 * 1024)
        h.connection.send(.tunnelData, payload)
        h.connection.close()
        let received = await TestIO.readToEnd(h.peer, silence: 10)
        XCTAssertEqual(received, TestIO.frame(.tunnelData, payload), "the final frame isn't cut off by the close")
    }

    func testBacklogIsCountedAndDrainIsReported() async throws {
        let h = try harness()
        let drained = Locked(0)
        h.connection.drainThreshold = 64 * 1024
        h.connection.onDrained = { drained.mutate { $0 += 1 } }
        // More than the socket buffers hold, with nobody reading.
        for _ in 0..<32 { h.connection.send(.terminalOutput, Data(count: 64 * 1024)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(h.connection.pendingWriteBytes, 64 * 1024)
        XCTAssertEqual(drained.value, 0)
        let bytes = await TestIO.readToEndWhile(h.peer) { drained.value == 0 }
        XCTAssertGreaterThan(bytes, 0)
        await eventually("drained") { drained.value == 1 && h.connection.pendingWriteBytes == 0 }
    }

    // MARK: Terminal frames

    func testTerminalOutputFrameRoundTrip() throws {
        let bytes = Data("\u{1B}[31mred\u{1B}[0m ✓".utf8)
        let payload = TerminalFrame.output(id: "term-1", offset: 0x0102_0304_0506_0708, bytes: bytes)
        let parsed = try XCTUnwrap(TerminalFrame.parseOutput(payload))
        XCTAssertEqual(parsed.id, "term-1")
        XCTAssertEqual(parsed.offset, 0x0102_0304_0506_0708)
        XCTAssertEqual(parsed.bytes, bytes)

        let maxOffset = try XCTUnwrap(TerminalFrame.parseOutput(TerminalFrame.output(id: "", offset: .max, bytes: Data())))
        XCTAssertEqual(maxOffset.id, "")
        XCTAssertEqual(maxOffset.offset, .max)
        XCTAssertTrue(maxOffset.bytes.isEmpty)
    }

    /// Frames come out of the connection as slices of a bigger buffer.
    func testTerminalFramesParseFromSlices() throws {
        let output = TerminalFrame.output(id: "abc", offset: 42, bytes: Data("xyz".utf8))
        let sliced = (Data([9, 9, 9]) + output).dropFirst(3)
        XCTAssertNotEqual(sliced.startIndex, 0)
        let parsed = try XCTUnwrap(TerminalFrame.parseOutput(sliced))
        XCTAssertEqual(parsed.id, "abc")
        XCTAssertEqual(parsed.offset, 42)
        XCTAssertEqual(parsed.bytes, Data("xyz".utf8))

        let input = TerminalFrame.input(id: "abc", bytes: Data([3]))
        let parsedInput = try XCTUnwrap(TerminalFrame.parseInput((Data([7]) + input).dropFirst()))
        XCTAssertEqual(parsedInput.id, "abc")
        XCTAssertEqual(parsedInput.bytes, Data([3]))
    }

    func testTruncatedTerminalFramesAreRejected() {
        XCTAssertNil(TerminalFrame.parseOutput(Data()))
        XCTAssertNil(TerminalFrame.parseInput(Data()))
        let output = TerminalFrame.output(id: "abcdef", offset: 1, bytes: Data())
        // Missing part of the offset.
        XCTAssertNil(TerminalFrame.parseOutput(output.prefix(output.count - 1)))
        // An id length pointing past the end.
        XCTAssertNil(TerminalFrame.parseInput(Data([10, 65, 66])))
    }

    func testTerminalInputFrameRoundTripAndLongIds() throws {
        let parsed = try XCTUnwrap(TerminalFrame.parseInput(TerminalFrame.input(id: "t", bytes: Data("ls\n".utf8))))
        XCTAssertEqual(parsed.id, "t")
        XCTAssertEqual(parsed.bytes, Data("ls\n".utf8))

        // Ids are length-prefixed with one byte: longer ones are cut, and
        // the bytes that follow still parse.
        let longId = String(repeating: "x", count: 300)
        let long = try XCTUnwrap(TerminalFrame.parseInput(TerminalFrame.input(id: longId, bytes: Data([1, 2]))))
        XCTAssertEqual(long.id, String(repeating: "x", count: 255))
        XCTAssertEqual(long.bytes, Data([1, 2]))
    }

    // MARK: JSON envelopes

    private func roundTrip(_ event: EngineEvent) throws -> EngineEvent {
        let data = try Wire.makeEncoder().encode(Wire.Event(event: event))
        let head = try Wire.makeDecoder().decode(Wire.ServerHead.self, from: data)
        XCTAssertEqual(head.type, "event")
        XCTAssertNil(head.id)
        return try Wire.makeDecoder().decode(Wire.Event.self, from: data).event
    }

    func testEventsRoundTrip() throws {
        guard case let .ports(ports) = try roundTrip(.ports([
            ListeningPort(port: 3000, addresses: ["127.0.0.1", "::1"], process: "node", suggested: true),
        ])) else { return XCTFail("ports") }
        XCTAssertEqual(ports.first?.addresses, ["127.0.0.1", "::1"])
        XCTAssertEqual(ports.first?.process, "node")

        guard case let .attention(chatId, workspaceId, critical) = try roundTrip(.attention(chatId: "c", workspaceId: "w", critical: true))
        else { return XCTFail("attention") }
        XCTAssertEqual([chatId, workspaceId], ["c", "w"])
        XCTAssertTrue(critical)

        guard case let .error(message) = try roundTrip(.error("boom")) else { return XCTFail("error") }
        XCTAssertEqual(message, "boom")

        guard case let .workspaceRemoved(id) = try roundTrip(.workspaceRemoved(id: "ws")) else { return XCTFail("removed") }
        XCTAssertEqual(id, "ws")
    }

    func testChatPatchRoundTripsWithDatesAtMillisecondPrecision() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000.123)
        let patch = ChatPatch(
            full: false,
            meta: nil,
            turnOrder: ["t1"],
            turns: [ChatTurnMeta(
                id: "t1", seq: 1, providerTurnId: nil, status: "running", errorMessage: nil,
                startedAt: started, completedAt: nil, checkpointBefore: nil, checkpointAfter: nil, stat: nil,
                itemIds: ["b1"]
            )],
            items: [
                .upsert(ChatItemWire(boxId: "b1", item: AgentItem(id: "i", turnId: "t1", status: .inProgress, content: .assistantMessage(text: "Hi")), createdAt: started)),
                .append(boxId: "b1", kind: .assistantText, text: " there ✓"),
            ]
        )
        guard case let .chat(id, decoded) = try roundTrip(.chat(id: "chat", patch)) else { return XCTFail("chat") }
        XCTAssertEqual(id, "chat")
        XCTAssertEqual(decoded.turnOrder, ["t1"])
        XCTAssertEqual(decoded.turns, patch.turns)
        XCTAssertEqual(decoded.turns.first?.startedAt.timeIntervalSince1970 ?? 0, started.timeIntervalSince1970, accuracy: 0.001)
        guard decoded.items.count == 2, case let .append(boxId, kind, text) = decoded.items[1] else { return XCTFail("items") }
        XCTAssertEqual(boxId, "b1")
        XCTAssertEqual(kind, .assistantText)
        XCTAssertEqual(text, " there ✓")
    }

    func testRequestEnvelopeCarriesMethodAndParams() throws {
        let data = try Wire.makeEncoder().encode(Wire.Request(id: 7, method: API.AttachTerminal.method, params: API.AttachTerminal(terminalId: "t", fromOffset: 12)))
        let head = try Wire.makeDecoder().decode(Wire.RequestHead.self, from: data)
        XCTAssertEqual(head.id, 7)
        XCTAssertEqual(head.method, "terminal.attach")
        let body = try Wire.makeDecoder().decode(Wire.RequestBody<API.AttachTerminal>.self, from: data)
        XCTAssertEqual(body.params.terminalId, "t")
        XCTAssertEqual(body.params.fromOffset, 12)
    }

    func testMethodNamesAreUnique() {
        let methods = [
            API.Hello.method, API.WatchPorts.method, API.SetFocus.method, API.AddRepository.method,
            API.RemoveRepository.method, API.UpdateRepository.method, API.ReorderRepositories.method,
            API.RepoRefs.method, API.RemoteBranches.method, API.OpenPullRequests.method,
            API.CreateWorkspace.method, API.ImportBranch.method, API.DeleteWorkspace.method,
            API.ReorderWorkspaces.method, API.ActivateWorkspace.method, API.CloseWorkspace.method,
            API.RefreshDiff.method, API.FullFileDiff.method, API.ListFiles.method, API.StartGitAction.method,
            API.FastPathGitAction.method, API.Merge.method, API.SetAutoMerge.method, API.RefreshPR.method,
            API.KickPR.method, API.RefreshConversation.method, API.PostComment.method, API.ReplyToThread.method,
            API.SetThreadResolved.method, API.CreateTerminal.method, API.AttachTerminal.method,
            API.DetachTerminal.method, API.ResizeTerminal.method, API.InterruptTerminal.method,
            API.CloseTerminal.method, API.TerminalText.method, API.ToggleRun.method, API.StartChat.method,
            API.ReopenChat.method, API.CloseChat.method, API.ClosedChats.method, API.SubscribeChat.method,
            API.UnsubscribeChat.method, API.ChatCommand.method, API.OpenChatInTerminal.method,
            API.CheckpointDiff.method, API.SaveSettings.method, API.ListDirectory.method, API.ReadFile.method,
            API.UploadFile.method,
        ]
        XCTAssertEqual(Set(methods).count, methods.count, "duplicate wire method names")
    }

    /// Engines from before `features` existed leave it out.
    func testHelloResultDecodesWithoutFeatures() throws {
        let snapshot = EngineSnapshot(
            global: GlobalSnapshot(repositories: [], workspacesByRepo: [:], settings: AppSettings(), repoMetadataByRepo: [:], prTrackerStatus: .ok, rateLimits: [:]),
            diffs: [:], prs: [:], conversations: [:], statuses: [:], activity: []
        )
        let result = API.HelloResult(protocolVersion: 1, engineVersion: "0.1", hostName: "h", platform: "Linux", homeDirectory: "/home/u", dataDirectory: "/d", snapshot: snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Wire.makeEncoder().encode(result)) as? [String: Any])
        object.removeValue(forKey: "features")
        let decoded = try Wire.makeDecoder().decode(API.HelloResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.features)
        XCTAssertEqual(decoded.platform, "Linux")
    }

    // MARK: Sockets

    private func shortSocketPath() -> String {
        // sockaddr_un is small; the test data dir may not be.
        "/tmp/jl-\(getpid())-\(UUID().uuidString.prefix(6)).sock"
    }

    func testUnixSocketListenConnectAccept() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let listener = try Sockets.listen(path: path)
        defer { _ = close(listener) }
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "the socket is private to its user")

        let client = try XCTUnwrap(Sockets.connect(path: path))
        defer { _ = close(client) }
        let server = try XCTUnwrap(Sockets.accept(listener))
        defer { _ = close(server) }
        XCTAssertNil(writeAll(fd: client, Data("ping".utf8)))
        XCTAssertEqual(TestIO.readExactly(server, count: 4), Data("ping".utf8))
    }

    func testListenReplacesAStaleSocketFile() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let first = try Sockets.listen(path: path)
        _ = close(first)
        // The file is left behind, as after a crash.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(Sockets.connect(path: path), "nothing listens on a stale socket")
        let second = try Sockets.listen(path: path)
        defer { _ = close(second) }
        let client = try XCTUnwrap(Sockets.connect(path: path))
        _ = close(client)
    }

    func testConnectToMissingOrOverlongPathFails() throws {
        XCTAssertNil(Sockets.connect(path: "/tmp/definitely-not-here-\(UUID().uuidString).sock"))
        let long = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        XCTAssertNil(Sockets.connect(path: long))
        XCTAssertThrowsError(try Sockets.listen(path: long))
    }

    func testWriteAllWaitsOutAFullNonBlockingSocket() async throws {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        defer { _ = close(a); _ = close(b) }
        _ = fcntl(a, F_SETFL, fcntl(a, F_GETFL) | O_NONBLOCK)
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let writer = TestIO.background { writeAll(fd: a, payload) }
        let reader = TestIO.background { () -> Data in
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while data.count < payload.count {
                usleep(50)
                let n = read(b, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer[0..<n])
            }
            return data
        }
        let failure = await writer.value
        XCTAssertNil(failure, "EAGAIN is waited out, not reported")
        let received = await reader.value
        XCTAssertTrue(received == payload)
    }

    func testWriteAllReportsAPeerThatHungUp() throws {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        defer { _ = close(a) }
        _ = close(b)
        XCTAssertEqual(writeAll(fd: a, Data("x".utf8)), EPIPE)
    }
}

extension TestIO {
    /// Read and discard while `keepGoing` holds; returns the byte count.
    static func readToEndWhile(_ fd: Int32, _ keepGoing: @escaping @Sendable () -> Bool) async -> Int {
        await background {
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 65536)
            let deadline = Date().addingTimeInterval(20)
            while keepGoing(), Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 100) > 0 else { continue }
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                total += n
            }
            return total
        }.value
    }
}
