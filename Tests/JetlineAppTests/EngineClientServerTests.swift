import XCTest
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

/// `EngineClient` against a scripted engine (exact bytes on the wire), and
/// `EngineServer`'s dispatch, error codes and fan-out against a real one.
@MainActor
final class EngineClientServerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
        _ = TestSupport.dataDir
    }

    private var cleanups: [@MainActor () async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
    }

    // MARK: - Scripted engine

    /// The engine end of a socketpair: every request is handed to `respond`
    /// (on the connection's read queue) with a way to send raw JSON back.
    private final class ScriptedEngine: @unchecked Sendable {
        let connection: FramedConnection
        let requests = Locked<[(id: UInt64, method: String)]>([])
        let terminalInput = Locked<[(id: String, bytes: Data)]>([])
        var respond: @Sendable (_ id: UInt64, _ method: String, _ engine: ScriptedEngine) -> Void = { _, _, _ in }

        init(connection: FramedConnection) {
            self.connection = connection
        }

        func sendJSON(_ json: String) {
            connection.send(.message, Data(json.utf8))
        }

        func sendEvent(_ event: EngineEvent) {
            connection.send(.message, try! Wire.makeEncoder().encode(Wire.Event(event: event)))
        }
    }

    private func scripted() throws -> (EngineClient, ScriptedEngine) {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        let engine = ScriptedEngine(connection: FramedConnection(readFD: a, writeFD: a, label: "scripted"))
        engine.connection.onFrames = { [engine] frames in
            for frame in frames {
                switch frame.kind {
                case .message:
                    guard let head = try? Wire.makeDecoder().decode(Wire.RequestHead.self, from: frame.payload) else { continue }
                    engine.requests.mutate { $0.append((head.id, head.method)) }
                    engine.respond(head.id, head.method, engine)
                case .terminalInput:
                    if let (id, bytes) = TerminalFrame.parseInput(frame.payload) {
                        engine.terminalInput.mutate { $0.append((id, bytes)) }
                    }
                default:
                    continue
                }
            }
        }
        engine.connection.start()
        let client = EngineClient(connection: FramedConnection(readFD: b, writeFD: b, label: "client"))
        client.start()
        cleanups.append { client.close(); engine.connection.close() }
        return (client, engine)
    }

    func testEventsSentBeforeAResponseAreSeenBeforeTheCallReturns() async throws {
        let (client, engine) = try scripted()
        var seen: [String] = []
        client.onEvent = { if case let .error(message) = $0 { seen.append(message) } }
        engine.respond = { id, _, engine in
            engine.sendEvent(.error("first"))
            engine.sendEvent(.error("second"))
            engine.sendJSON(#"{"type":"response","id":\#(id),"result":{}}"#)
        }
        _ = try await client.call(API.SetFocus(workspaceId: nil))
        XCTAssertEqual(seen, ["first", "second"])
    }

    func testOptionalResultsCanBeNull() async throws {
        let (client, engine) = try scripted()
        engine.respond = { id, method, engine in
            switch method {
            case API.ReadFile.method: engine.sendJSON(#"{"type":"response","id":\#(id),"result":null}"#)
            default: engine.sendJSON(#"{"type":"response","id":\#(id)}"#)
            }
        }
        let data = try await client.call(API.ReadFile(path: "/nope", maxBytes: 1))
        XCTAssertNil(data)
        let tab = try await client.call(API.FastPathGitAction(workspaceId: "w", action: .pullUpdates))
        XCTAssertNil(tab, "a missing result is nil too")
    }

    func testErrorResponsesAreThrownWithTheirCode() async throws {
        let (client, engine) = try scripted()
        engine.respond = { id, _, engine in
            engine.sendJSON(#"{"type":"response","id":\#(id),"error":{"message":"That workspace no longer exists.","code":"noWorkspace"}}"#)
        }
        do {
            _ = try await client.call(API.RefreshDiff(workspaceId: "gone"))
            XCTFail("expected an error")
        } catch let error as WireError {
            XCTAssertEqual(error, WireError("That workspace no longer exists.", code: "noWorkspace"))
            XCTAssertEqual(error.localizedDescription, "That workspace no longer exists.")
        }
    }

    func testAnEmptyOrUnreadableResponseIsAnError() async throws {
        let (client, engine) = try scripted()
        engine.respond = { id, method, engine in
            if method == API.TerminalText.method {
                engine.sendJSON(#"{"type":"response","id":\#(id)}"#)
            } else {
                engine.sendJSON(#"{"type":"response","id":\#(id),"result":{"unexpected":true}}"#)
            }
        }
        do {
            _ = try await client.call(API.TerminalText(terminalId: "t"))
            XCTFail("expected an error")
        } catch let error as WireError {
            XCTAssertTrue(error.message.contains("empty response to terminal.text"), error.message)
        }
        do {
            _ = try await client.call(API.CreateTerminal(workspaceId: "w", agent: .shell))
            XCTFail("expected an error")
        } catch let error as WireError {
            XCTAssertTrue(error.message.contains("Couldn't read the engine's response to terminal.create"), error.message)
        }
    }

    func testResponsesAreMatchedByIdWhateverTheirOrder() async throws {
        let (client, engine) = try scripted()
        // Hold every reply until three requests are in, then answer in reverse.
        engine.respond = { _, _, engine in
            let all = engine.requests.value
            guard all.count == 3 else { return }
            for request in all.reversed() {
                engine.sendJSON(#"{"type":"response","id":\#(request.id),"result":"\#(request.method)-\#(request.id)"}"#)
            }
        }
        async let a = client.call(API.TerminalText(terminalId: "a"))
        async let b = client.call(API.TerminalText(terminalId: "b"))
        async let c = client.call(API.UploadFile(name: "x", data: Data()))
        let results = try await [a, b, c]
        let ids = engine.requests.value.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "every request gets its own id")
        for (result, request) in zip(results.sorted(), engine.requests.value.sorted { $0.id < $1.id }.map { "\($0.method)-\($0.id)" }.sorted()) {
            XCTAssertEqual(result, request)
        }
    }

    func testPendingCallsFailWhenTheEngineGoesAway() async throws {
        let (client, engine) = try scripted()
        var closes = 0
        client.onClose = { closes += 1 }
        engine.respond = { _, _, engine in engine.connection.close() }
        do {
            _ = try await client.call(API.SetFocus(workspaceId: nil))
            XCTFail("expected disconnected")
        } catch let error as WireError {
            XCTAssertEqual(error, .disconnected)
        }
        await eventually("onClose") { closes == 1 && client.isClosed }
        do {
            _ = try await client.call(API.SetFocus(workspaceId: nil))
            XCTFail("expected disconnected")
        } catch let error as WireError {
            XCTAssertEqual(error, .disconnected, "later calls fail straight away")
        }
        XCTAssertEqual(closes, 1)
    }

    func testClosingTheClientFailsWhatIsInFlight() async throws {
        let (client, engine) = try scripted()
        engine.respond = { _, _, _ in } // never answers
        let call = Task { @MainActor in try await client.call(API.SetFocus(workspaceId: nil)) }
        await eventually("request sent") { engine.requests.value.count == 1 }
        client.close()
        do {
            _ = try await call.value
            XCTFail("expected disconnected")
        } catch let error as WireError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    func testTerminalOutputIsRoutedByTerminalId() async throws {
        let (client, engine) = try scripted()
        var got: [(UInt64, String)] = []
        client.setTerminalHandler("a") { offset, bytes in got.append((offset, String(decoding: bytes, as: UTF8.self))) }
        engine.connection.send(.terminalOutput, TerminalFrame.output(id: "a", offset: 0, bytes: Data("one".utf8)))
        engine.connection.send(.terminalOutput, TerminalFrame.output(id: "b", offset: 0, bytes: Data("not mine".utf8)))
        engine.connection.send(.terminalOutput, TerminalFrame.output(id: "a", offset: 3, bytes: Data("two".utf8)))
        await eventually("output") { got.count == 2 }
        XCTAssertEqual(got.map(\.0), [0, 3])
        XCTAssertEqual(got.map(\.1), ["one", "two"])

        client.setTerminalHandler("a", nil)
        engine.connection.send(.terminalOutput, TerminalFrame.output(id: "a", offset: 6, bytes: Data("three".utf8)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(got.count, 2, "no handler, no delivery")
    }

    func testTerminalInputGoesOutAsBinaryFrames() async throws {
        let (client, engine) = try scripted()
        client.sendTerminalInput("t1", Data("ls\n".utf8))
        client.sendTerminalInput("t1", Data())
        client.sendTerminalInput("t2", Data([0x03]))
        await eventually("input") { engine.terminalInput.value.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        let input = engine.terminalInput.value
        XCTAssertEqual(input.count, 2, "empty input isn't sent")
        XCTAssertEqual(input.map(\.id), ["t1", "t2"])
        XCTAssertEqual(input.map(\.bytes), [Data("ls\n".utf8), Data([0x03])])
    }

    func testAnUndecodableEventDoesNotStopTheStream() async throws {
        let (client, engine) = try scripted()
        var seen: [String] = []
        client.onEvent = { if case let .error(message) = $0 { seen.append(message) } }
        engine.sendJSON(#"{"type":"event","event":{"fromTheFuture":{}}}"#)
        engine.sendJSON(#"not json at all"#)
        engine.sendEvent(.error("still here"))
        await eventually("event") { seen == ["still here"] }
    }

    // MARK: - Real engine

    private func served() throws -> (EngineServer, EngineClient, Locked<[EngineEvent]>) {
        let events = Locked<[EngineEvent]>([])
        let (server, client) = try TestSupport.engineAndClient { event in events.mutate { $0.append(event) } }
        cleanups.append {
            client.close()
            await server.engine.shutdown()
        }
        return (server, client, events)
    }

    private func hello(_ client: EngineClient) async throws -> API.HelloResult {
        try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "test"))
    }

    private func expectError<T>(_ code: String, _ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as WireError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private struct Bogus: RPC {
        typealias Response = Empty
        static let method = "no.such.method"
    }

    func testUnknownMethodsAndMalformedRequestsAreAnswered() async throws {
        let (server, client, _) = try served()
        _ = try await hello(client)
        await expectError("unknownMethod") { try await client.call(Bogus()) }

        // Raw requests on a second connection.
        let (a, b) = try XCTUnwrap(Sockets.pair())
        server.accept(FramedConnection(readFD: a, writeFD: a, label: "raw"))
        defer { _ = close(b) }
        XCTAssertNil(writeAll(fd: b, TestIO.frame(json: #"{"id":1,"method":"hello","params":{"protocolVersion":\#(Wire.protocolVersion),"clientName":"raw"}}"#)))
        // Params of the wrong shape, with an id to answer to.
        XCTAssertNil(writeAll(fd: b, TestIO.frame(json: #"{"id":2,"method":"terminal.text","params":{"terminalId":42}}"#)))
        // Missing method: answered as malformed.
        XCTAssertNil(writeAll(fd: b, TestIO.frame(json: #"{"id":3}"#)))
        // No id at all: nothing to answer, and the connection survives.
        XCTAssertNil(writeAll(fd: b, TestIO.frame(json: #"garbage"#)))
        XCTAssertNil(writeAll(fd: b, TestIO.frame(json: #"{"id":4,"method":"session.focus","params":{}}"#)))

        // Off the main actor, which the server needs to answer.
        let payloads = await TestIO.background { () -> [UInt64: Data] in
            var inbox = Data()
            var responses: [UInt64: Data] = [:]
            let deadline = Date().addingTimeInterval(10)
            while responses.count < 4, Date() < deadline {
                inbox += TestIO.readExactly(b, count: 1, timeout: 1000) + Self.drainNow(b)
                while inbox.count >= 4 {
                    let length = inbox.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                    guard inbox.count >= 4 + length else { break }
                    let payload = inbox.subdata(in: (inbox.startIndex + 5)..<(inbox.startIndex + 4 + length))
                    inbox.removeFirst(4 + length)
                    if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                       object["type"] as? String == "response", let id = (object["id"] as? NSNumber)?.uint64Value {
                        responses[id] = payload
                    }
                }
            }
            return responses
        }.value
        let responses = payloads.compactMapValues { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertNil(responses[1]?["error"])
        XCTAssertNotNil((responses[2]?["error"] as? [String: Any])?["message"], "wrong params are an error, not a hang")
        XCTAssertEqual((responses[3]?["error"] as? [String: Any])?["code"] as? String, "badRequest")
        XCTAssertNotNil(responses[4]?["result"], "still serving after garbage")
    }

    nonisolated private static func drainNow(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return data }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return data }
            data.append(contentsOf: buffer[0..<n])
        }
    }

    func testAFailedHelloMustBeRetriedBeforeOtherRequests() async throws {
        let (_, client, _) = try served()
        await expectError("protocolMismatch") {
            try await client.call(API.Hello(protocolVersion: Wire.protocolVersion + 1, clientName: "future"))
        }
        await expectError("notReady") { try await client.call(API.SetFocus(workspaceId: nil)) }
        _ = try await hello(client)
        _ = try await client.call(API.SetFocus(workspaceId: nil))
    }

    func testEventsGoOnlyToGreetedClientsAndEveryOneOfThem() async throws {
        let (server, first, firstEvents) = try served()
        _ = try await hello(first)
        let secondEvents = Locked<[EngineEvent]>([])
        let second = try TestSupport.connect(to: server) { event in secondEvents.mutate { $0.append(event) } }
        let silentEvents = Locked<[EngineEvent]>([])
        let silent = try TestSupport.connect(to: server) { event in silentEvents.mutate { $0.append(event) } }
        cleanups.append { second.close(); silent.close() }
        _ = try await hello(second)
        await eventually("three clients") { server.clientCount == 3 }

        let repo = try await first.call(API.AddRepository(path: try await TestSupport.makeRepo()))
        func hasRepo(_ events: Locked<[EngineEvent]>) -> Bool {
            events.value.contains { if case let .global(g) = $0 { g.repositories.contains { $0.id == repo.id } } else { false } }
        }
        await eventually("both greeted clients hear about it") { hasRepo(firstEvents) && hasRepo(secondEvents) }
        XCTAssertTrue(silentEvents.value.isEmpty, "no events before hello")

        // A late hello gets it in the snapshot instead.
        let late = try await hello(silent)
        XCTAssertTrue(late.snapshot.global.repositories.contains { $0.id == repo.id })

        second.close()
        await eventually("client count drops") { server.clientCount == 2 }
    }

    func testMissingThingsHaveErrorCodes() async throws {
        let (_, client, _) = try served()
        _ = try await hello(client)
        await expectError("noWorkspace") { try await client.call(API.DeleteWorkspace(workspaceId: "nope")) }
        await expectError("noWorkspace") { try await client.call(API.CreateTerminal(workspaceId: "nope", agent: .shell)) }
        await expectError("noRepository") { try await client.call(API.RepoRefs(repoId: "nope")) }
        await expectError("noRepository") { try await client.call(API.CreateWorkspace(repoId: "nope", name: "x")) }
        await expectError("noTerminal") { try await client.call(API.AttachTerminal(terminalId: "nope", fromOffset: nil)) }
        await expectError("noChat") { try await client.call(API.SubscribeChat(chatId: "nope")) }
        await expectError("noChat") { try await client.call(API.ChatCommand(chatId: "nope", command: .interrupt)) }
        // Things that are simply absent aren't errors.
        let text = try await client.call(API.TerminalText(terminalId: "nope"))
        XCTAssertEqual(text, "")
        _ = try await client.call(API.ResizeTerminal(terminalId: "nope", size: TerminalSize(cols: 1, rows: 1)))
    }

    func testRepositoriesReorderAndRemove() async throws {
        let (_, client, events) = try served()
        _ = try await hello(client)
        let one = try await client.call(API.AddRepository(path: try await TestSupport.makeRepo()))
        let two = try await client.call(API.AddRepository(path: try await TestSupport.makeRepo()))
        func all() -> [String]? {
            for event in events.value.reversed() {
                if case let .global(g) = event { return g.repositories.map(\.id) }
            }
            return nil
        }
        func order() -> [String]? { all()?.filter { [one.id, two.id].contains($0) } }
        await eventually("both listed") { order()?.count == 2 }
        let initial = try XCTUnwrap(order())
        let everything = try XCTUnwrap(all())
        _ = try await client.call(API.ReorderRepositories(orderedIds: initial.reversed() + everything.filter { !initial.contains($0) }))
        await eventually("reordered") { order() == initial.reversed() }

        // A terminal in the repo's base checkout goes with it.
        let baseId = Engine.repositoryBaseWorkspacePrefix + one.id
        let terminal = try await client.call(API.CreateTerminal(workspaceId: baseId, agent: .shell, size: TerminalSize(cols: 80, rows: 24)))
        _ = try await client.call(API.RemoveRepository(repoId: one.id))
        await eventually("removed") { order() == [two.id] }
        await eventually("its base workspace is dropped") {
            events.value.contains { if case let .workspaceRemoved(id) = $0 { id == baseId } else { false } }
        }
        await expectError("noTerminal") { try await client.call(API.AttachTerminal(terminalId: terminal.id, fromOffset: nil)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path), "removing from Jetline leaves the checkout alone")
    }

    // MARK: Terminals

    func testTwoClientsWatchOneTerminalAndDetachStopsOutput() async throws {
        let (server, first, events) = try served()
        _ = try await hello(first)
        let second = try TestSupport.connect(to: server)
        cleanups.append { second.close() }
        _ = try await hello(second)

        let repo = try await first.call(API.AddRepository(path: try await TestSupport.makeRepo()))
        let terminal = try await first.call(API.CreateTerminal(
            workspaceId: Engine.repositoryBaseWorkspacePrefix + repo.id, agent: .shell, size: TerminalSize(cols: 80, rows: 24)
        ))
        var firstText = "", secondText = ""
        first.setTerminalHandler(terminal.id) { _, bytes in firstText += String(decoding: bytes, as: UTF8.self) }
        second.setTerminalHandler(terminal.id) { _, bytes in secondText += String(decoding: bytes, as: UTF8.self) }
        _ = try await first.call(API.AttachTerminal(terminalId: terminal.id, fromOffset: nil))
        _ = try await second.call(API.AttachTerminal(terminalId: terminal.id, fromOffset: nil))

        // Input from either client reaches the one shell.
        second.sendTerminalInput(terminal.id, Data("echo from-$((2*21))\n".utf8))
        await eventually("both see it") { firstText.contains("from-42") && secondText.contains("from-42") }

        _ = try await second.call(API.DetachTerminal(terminalId: terminal.id))
        let before = secondText
        first.sendTerminalInput(terminal.id, Data("echo after-$((3*3))\n".utf8))
        await eventually("first sees it") { firstText.contains("after-9") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(secondText, before, "a detached client gets nothing more")

        // Re-attaching past the end replays nothing and reports where it is.
        let end = UInt64(try await first.call(API.TerminalText(terminalId: terminal.id)).utf8.count)
        let attach = try await second.call(API.AttachTerminal(terminalId: terminal.id, fromOffset: .max))
        XCTAssertEqual(attach.bufferStart, 0)
        XCTAssertGreaterThanOrEqual(attach.replayFrom, end / 2)
        XCTAssertEqual(attach.info.id, terminal.id)
        XCTAssertTrue(attach.info.hasStarted)

        // The shell exits: its tab reports the code.
        first.sendTerminalInput(terminal.id, Data("exit 3\n".utf8))
        await eventually("exit code") {
            events.value.contains {
                if case let .workspaceStatus(_, status) = $0 { status.terminals.contains { $0.id == terminal.id && $0.exitCode == 3 } } else { false }
            }
        }
    }

    // MARK: Files

    func testDirectoryListingsSortFoldersFirstAndSkipHiddenFiles() async throws {
        let (_, client, _) = try served()
        _ = try await hello(client)
        let dir = TestSupport.dataDir.appendingPathComponent("listing-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        for sub in ["b-dir", "A-dir", "repo"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: dir.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        for file in ["file10.txt", "file2.txt", ".hidden"] {
            try Data().write(to: dir.appendingPathComponent(file))
        }
        let listing = try await client.call(API.ListDirectory(path: dir.path))
        XCTAssertEqual(listing.map(\.name), ["A-dir", "b-dir", "repo", "file2.txt", "file10.txt"])
        XCTAssertEqual(listing.filter(\.isGitRepo).map(\.name), ["repo"])
        XCTAssertEqual(listing.filter(\.isDirectory).count, 3)
        XCTAssertEqual(listing.first?.path, dir.appendingPathComponent("A-dir").path)

        await expectErrorMessage { try await client.call(API.ListDirectory(path: dir.appendingPathComponent("nope").path)) }
    }

    private func expectErrorMessage<T>(_ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected an error")
        } catch let error as WireError {
            XCTAssertFalse(error.message.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testReadFileCapsSizeAndReturnsNilForWhatIsNotAFile() async throws {
        let (_, client, _) = try served()
        _ = try await hello(client)
        let file = TestSupport.dataDir.appendingPathComponent("read-\(UUID().uuidString.prefix(6)).bin")
        try Data((0..<100).map { UInt8($0) }).write(to: file)
        let head = try await client.call(API.ReadFile(path: file.path, maxBytes: 10))
        XCTAssertEqual(head, Data((0..<10).map { UInt8($0) }))
        let none = try await client.call(API.ReadFile(path: file.path, maxBytes: -5))
        XCTAssertTrue(none?.isEmpty ?? true)
        let missing = try await client.call(API.ReadFile(path: file.path + ".missing", maxBytes: 10))
        XCTAssertNil(missing)
        let directory = try await client.call(API.ReadFile(path: TestSupport.dataDir.path, maxBytes: 10))
        XCTAssertNil(directory)
    }

    func testUploadsGetUniqueNamesWithoutPathSeparators() async throws {
        let (_, client, _) = try served()
        _ = try await hello(client)
        let first = try await client.call(API.UploadFile(name: "../../etc/passwd", data: Data("a".utf8)))
        let second = try await client.call(API.UploadFile(name: "../../etc/passwd", data: Data("b".utf8)))
        XCTAssertNotEqual(first, second)
        for path in [first, second] {
            XCTAssertEqual((path as NSString).deletingLastPathComponent, Engine.uploadsDirectory.path)
            XCTAssertFalse((path as NSString).lastPathComponent.contains("/"))
            XCTAssertTrue((path as NSString).lastPathComponent.hasSuffix(".._.._etc_passwd"))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second)), Data("b".utf8))
    }

    func testTildeExpandsToTheEngineUsersHome() {
        let home = Platform.homeDirectory.path
        XCTAssertEqual(Engine.expandTilde("~"), home)
        XCTAssertEqual(Engine.expandTilde("~/src/app"), (home as NSString).appendingPathComponent("src/app"))
        XCTAssertEqual(Engine.expandTilde("/abs/~/x"), "/abs/~/x")
        XCTAssertEqual(Engine.expandTilde("~other/x"), "~other/x")
    }

    // MARK: Terminal buffer

    func testTerminalBufferPublishesToItsSinkWithOffsets() {
        let buffer = TerminalBuffer(capacity: 100)
        let received = Locked<[(UInt64, Data)]>([])
        buffer.setSink { offset, data in received.mutate { $0.append((offset, data)) } }
        buffer.publish(Data("abc".utf8))
        buffer.publish(Data("defg".utf8))
        XCTAssertEqual(received.value.map(\.0), [0, 3])
        buffer.setSink(nil)
        buffer.publish(Data("h".utf8))
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(buffer.range.end, 8)
        let (offset, bytes) = buffer.read(from: 8)
        XCTAssertEqual(offset, 8)
        XCTAssertTrue(bytes.isEmpty, "reading at the end is empty")
        XCTAssertEqual(buffer.read(from: 1000).offset, 8, "past the end clamps to the end")
    }

    func testTerminalBufferTrimsInBulkAndKeepsTheNewestBytes() {
        let buffer = TerminalBuffer(capacity: 1000)
        var all = Data()
        for i in 0..<50 {
            let chunk = Data(repeating: UInt8(i), count: 97)
            all += chunk
            XCTAssertEqual(buffer.append(chunk), UInt64(i * 97), "offsets stay absolute across trims")
            XCTAssertLessThanOrEqual(buffer.range.end - buffer.range.start, 1000)
        }
        let range = buffer.range
        XCTAssertEqual(range.end, UInt64(all.count))
        let (offset, bytes) = buffer.read(from: nil)
        XCTAssertEqual(offset, range.start)
        XCTAssertEqual(bytes, all.suffix(Int(range.end - range.start)))
    }
}
