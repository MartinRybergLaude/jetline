import XCTest
import Observation
@testable import JetlineApp

/// Chat transcript sync: `ChatPublisher` turning a `ChatEngine` into
/// patches, `ChatSession` (macOS) rebuilding it from them, and the
/// `ObservationPump` underneath. No agent CLI runs: the engine's
/// executable resolver finds nothing, and streaming is simulated by
/// editing its items the way its reducer does.
@MainActor
final class ChatSyncTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = TestSupport.dataDir
    }

    private var chats: [ChatEngine] = []

    override func tearDown() async throws {
        for chat in chats { chat.close() }
        chats = []
    }

    private func makeChat() async throws -> ChatEngine {
        let chat = ChatEngine(
            workspaceId: "sync-test",
            cwd: try await TestSupport.makeRepo(),
            provider: .claude,
            model: nil,
            effort: nil,
            runtimeMode: .supervised,
            rateLimits: AgentRateLimits(),
            executableResolver: { _ in nil }
        )
        chats.append(chat)
        return chat
    }

    /// Patches as a client gets them: through JSON.
    private func wire(_ patch: ChatPatch) throws -> ChatPatch {
        try Wire.makeDecoder().decode(ChatPatch.self, from: Wire.makeEncoder().encode(patch))
    }

    // MARK: ObservationPump

    @Observable
    final class Model {
        var value = 0
        var untracked = 0
    }

    func testPumpTakesABaselineThenEmitsCoalescedChanges() async throws {
        let model = Model()
        var emitted: [Int] = []
        let pump = ObservationPump(delay: .milliseconds(30), read: { model.value }, emit: { emitted.append($0) })
        pump.start()
        XCTAssertEqual(pump.current, 0)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(emitted, [], "the baseline isn't emitted")

        model.value = 1
        model.value = 2
        model.value = 3
        await eventually("one emit") { emitted == [3] }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(emitted, [3], "a burst is one emit of the latest value")

        // Still armed after an emit.
        model.value = 4
        await eventually("second emit") { emitted == [3, 4] }
    }

    func testPumpSkipsUnchangedValuesAndUntrackedProperties() async throws {
        let model = Model()
        var emitted: [Int] = []
        let pump = ObservationPump(delay: .milliseconds(20), read: { model.value }, emit: { emitted.append($0) })
        pump.start()
        model.untracked = 9
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(emitted, [])
        model.value = 5
        model.value = 0 // back where it was before the delay ran out
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(emitted, [], "a change that's undone isn't emitted")
        model.value = 7
        await eventually("emit") { emitted == [7] }
    }

    func testPumpFlushEmitsAtOnceAndStopSilencesIt() async throws {
        let model = Model()
        var emitted: [Int] = []
        let pump = ObservationPump(delay: .seconds(5), read: { model.value }, emit: { emitted.append($0) })
        pump.start()
        pump.flush()
        XCTAssertEqual(emitted, [], "nothing pending, nothing flushed")
        model.value = 1
        // Let the change notification hop onto the main actor.
        try await Task.sleep(for: .milliseconds(20))
        pump.flush()
        XCTAssertEqual(emitted, [1], "flush doesn't wait out the delay")

        pump.stop()
        model.value = 2
        try await Task.sleep(for: .milliseconds(50))
        pump.flush()
        XCTAssertEqual(emitted, [1])
    }

    // MARK: ChatPublisher

    func testFullPatchDescribesTheWholeChat() async throws {
        let chat = try await makeChat()
        let publisher = ChatPublisher(chat: chat) { _ in }
        publisher.start()
        defer { publisher.stop() }
        let full = try wire(publisher.fullPatch())
        XCTAssertTrue(full.full)
        XCTAssertEqual(full.meta?.id, chat.id)
        XCTAssertEqual(full.meta?.title, "New chat")
        XCTAssertEqual(full.meta?.workspaceId, "sync-test")
        XCTAssertEqual(full.turnOrder, [])
        XCTAssertTrue(full.turns.isEmpty && full.items.isEmpty)
    }

    func testASendBecomesIncrementalPatches() async throws {
        let chat = try await makeChat()
        var patches: [ChatPatch] = []
        let publisher = ChatPublisher(chat: chat) { patches.append($0) }
        publisher.start()
        defer { publisher.stop() }
        _ = publisher.fullPatch()

        chat.send(text: "Fix the login bug")
        // The optimistic turn and user message go out first.
        await eventually("new turn") { patches.contains { $0.turnOrder?.count == 1 } }
        let first = try XCTUnwrap(patches.first { $0.turnOrder?.count == 1 })
        XCTAssertFalse(first.full)
        XCTAssertEqual(first.turns.first?.status, "running")
        XCTAssertEqual(first.meta?.title, "Fix the login bug")
        guard case let .upsert(wire)? = first.items.first, case let .userMessage(message) = wire.item.content else {
            return XCTFail("expected the user message, got \(first.items)")
        }
        XCTAssertEqual(message.text, "Fix the login bug")
        XCTAssertEqual(first.turns.first?.itemIds, [wire.boxId])

        // No CLI: the turn fails and the connection reports why.
        await eventually("turn failed", timeout: 15) { patches.contains { $0.turns.contains { $0.status == "failed" } } }
        let failed = try XCTUnwrap(patches.last { $0.turns.contains { $0.status == "failed" } })
        XCTAssertNil(failed.turnOrder, "the set of turns didn't change")
        XCTAssertTrue(failed.items.isEmpty, "the user message didn't change either")
        XCTAssertNotNil(failed.turns.first?.errorMessage)
        await eventually("connection failed") {
            patches.contains { if case .failed? = $0.meta?.connection { true } else { false } }
        }
    }

    func testMetaOnlyChangesSendOnlyMeta() async throws {
        let chat = try await makeChat()
        var patches: [ChatPatch] = []
        let publisher = ChatPublisher(chat: chat) { patches.append($0) }
        publisher.start()
        defer { publisher.stop() }
        _ = publisher.fullPatch()
        chat.setRuntimeMode(.fullAccess)
        await eventually("meta patch") { !patches.isEmpty }
        let patch = try XCTUnwrap(patches.last)
        XCTAssertEqual(patch.meta?.runtimeMode, .fullAccess)
        XCTAssertNil(patch.turnOrder)
        XCTAssertTrue(patch.turns.isEmpty && patch.items.isEmpty)

        let count = patches.count
        chat.setRuntimeMode(.fullAccess)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(patches.count, count, "no change, no patch")
    }

    func testStreamedTextGoesOutAsAppends() async throws {
        let chat = try await makeChat()
        var patches: [ChatPatch] = []
        let publisher = ChatPublisher(chat: chat) { patches.append($0) }
        publisher.start()
        defer { publisher.stop() }
        chat.send(text: "Explain")
        await eventually("turn settles", timeout: 15) { chat.turns.first?.status == .failed }
        let turn = try XCTUnwrap(chat.turns.first)
        _ = publisher.fullPatch()
        patches.removeAll()

        // A reply streaming in, as the reducer builds it.
        let box = ChatItemBox(id: "answer", item: AgentItem(id: "a1", turnId: "p1", status: .inProgress, content: .assistantMessage(text: "Sure")))
        turn.items.append(box)
        await eventually("upsert") { patches.contains { $0.items.contains { if case .upsert(let w) = $0 { w.boxId == "answer" } else { false } } } }
        patches.removeAll()
        box.item.append(", here's how", kind: .assistantText)
        await eventually("append") { !patches.isEmpty }
        box.item.append(" it works — ✓", kind: .assistantText)
        await eventually("second append") { patches.count == 2 }
        let appended = patches.flatMap(\.items).compactMap { change -> String? in
            if case let .append(boxId, kind, text) = change, boxId == "answer", kind == .assistantText { return text }
            return nil
        }
        XCTAssertEqual(appended.joined(), ", here's how it works — ✓")

        // A status change can't be an append.
        patches.removeAll()
        box.item.status = .completed
        await eventually("upsert on completion") { !patches.isEmpty }
        guard case let .upsert(wire)? = patches.last?.items.first else { return XCTFail("expected an upsert") }
        XCTAssertEqual(wire.item.status, .completed)
    }

    func testANewSubscribersFullPatchFlushesPendingChangesToExistingOnes() async throws {
        let chat = try await makeChat()
        var patches: [ChatPatch] = []
        let publisher = ChatPublisher(chat: chat) { patches.append($0) }
        publisher.start()
        defer { publisher.stop() }
        chat.setInteractionMode(.plan)
        // Before the pump's delay: the full patch sends the change first.
        let full = publisher.fullPatch()
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.meta?.interactionMode, .plan)
        XCTAssertEqual(full.meta?.interactionMode, .plan)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(patches.count, 1, "and isn't sent twice")
    }

    func testStreamedSuffixCoversEveryStreamingField() {
        func item(_ content: AgentItem.Content, status: AgentItem.Status = .inProgress) -> AgentItem {
            AgentItem(id: "i", turnId: "t", status: status, content: content)
        }
        XCTAssertEqual(item(.reasoning(text: "ab")).streamedSuffix(since: item(.reasoning(text: "a")))?.1, "b")
        XCTAssertEqual(item(.reasoning(text: "ab")).streamedSuffix(since: item(.reasoning(text: "a")))?.0, .reasoningText)
        XCTAssertEqual(item(.plan(text: "1. x\n2. y")).streamedSuffix(since: item(.plan(text: "1. x")))?.0, .planText)

        let command = AgentItem.Command(command: "make", output: "building")
        var more = command
        more.output += "\ndone"
        XCTAssertEqual(item(.command(more)).streamedSuffix(since: item(.command(command)))?.1, "\ndone")
        var exited = more
        exited.exitCode = 0
        XCTAssertNil(item(.command(exited)).streamedSuffix(since: item(.command(command))), "other fields changed too")

        let tool = AgentItem.ToolCall(name: "Read", output: nil)
        var toolMore = tool
        toolMore.output = "line 1"
        XCTAssertEqual(item(.tool(toolMore)).streamedSuffix(since: item(.tool(tool)))?.0, .toolOutput)
        XCTAssertEqual(item(.tool(toolMore)).streamedSuffix(since: item(.tool(tool)))?.1, "line 1")

        // Not an append: shorter, rewritten, same, or a different kind.
        XCTAssertNil(item(.assistantMessage(text: "a")).streamedSuffix(since: item(.assistantMessage(text: "ab"))))
        XCTAssertNil(item(.assistantMessage(text: "xb")).streamedSuffix(since: item(.assistantMessage(text: "a"))))
        XCTAssertNil(item(.assistantMessage(text: "a")).streamedSuffix(since: item(.assistantMessage(text: "a"))))
        XCTAssertNil(item(.reasoning(text: "ab")).streamedSuffix(since: item(.assistantMessage(text: "a"))))
        var moved = item(.assistantMessage(text: "ab"))
        moved.parentId = "agent"
        XCTAssertNil(moved.streamedSuffix(since: item(.assistantMessage(text: "a"))))

        // Multi-byte text splits cleanly.
        let suffix = item(.assistantMessage(text: "héllo wörld 🎉")).streamedSuffix(since: item(.assistantMessage(text: "héllo")))
        XCTAssertEqual(suffix?.1, " wörld 🎉")
    }

    #if os(macOS)
    // MARK: ChatSession (the client mirror)

    private func session(title: String = "Chat", activity: ChatActivity = .idle) -> ChatSession {
        let connection = EngineConnection(target: .local)
        return ChatSession(
            summary: ChatSummary(id: "c1", provider: .claude, title: title, activity: activity),
            workspaceId: "w", cwd: "/tmp", backend: connection, files: EngineFiles(connection: connection)
        )
    }

    private func meta(title: String = "Chat", requests: [AgentRequest] = [], banner: String? = nil) -> ChatMeta {
        ChatMeta(
            id: "c1", workspaceId: "w", cwd: "/work", provider: .claude, createdAt: Date(timeIntervalSince1970: 1000),
            title: title, model: "opus", effort: nil, resolvedModel: nil, runtimeMode: .supervised,
            interactionMode: .normal, connection: .connected, remoteControl: .off, requests: requests, todos: [],
            usage: nil, models: [], commands: [], queued: [], banner: banner, isReverting: false, canRevert: true,
            terminalResumeArgs: nil
        )
    }

    private func turn(_ id: String, seq: Int, status: String = "running", items: [String]) -> ChatTurnMeta {
        ChatTurnMeta(
            id: id, seq: seq, providerTurnId: nil, status: status, errorMessage: nil, startedAt: Date(),
            completedAt: nil, checkpointBefore: nil, checkpointAfter: nil, stat: nil, itemIds: items
        )
    }

    private func upsert(_ boxId: String, _ content: AgentItem.Content, status: AgentItem.Status = .inProgress) -> ChatItemChange {
        .upsert(ChatItemWire(boxId: boxId, item: AgentItem(id: boxId, turnId: nil, status: status, content: content), createdAt: nil))
    }

    private func text(_ box: ChatItemBox) -> String? {
        switch box.item.content {
        case let .assistantMessage(text), let .reasoning(text): return text
        case let .userMessage(message): return message.text
        default: return nil
        }
    }

    func testSessionShowsTheSummaryUntilTheTranscriptArrives() throws {
        let chat = session(title: "From summary", activity: .working)
        XCTAssertFalse(chat.isLoaded)
        XCTAssertEqual(chat.activity, .working)
        XCTAssertTrue(chat.isWorking)
        chat.applySummary(ChatSummary(id: "c1", provider: .claude, title: "Renamed", activity: .needsInput))
        XCTAssertEqual(chat.title, "Renamed")
        XCTAssertEqual(chat.activity, .needsInput)

        chat.apply(try wire(ChatPatch(full: true, meta: meta(title: "Real title"), turnOrder: [], turns: [], items: [])))
        XCTAssertTrue(chat.isLoaded)
        XCTAssertEqual(chat.title, "Real title")
        XCTAssertEqual(chat.activity, .idle, "derived from the transcript once loaded")
        chat.applySummary(ChatSummary(id: "c1", provider: .claude, title: "Stale", activity: .working))
        XCTAssertEqual(chat.title, "Real title", "a loaded chat's title comes from its meta")
        XCTAssertEqual(chat.cwd, "/work")
        XCTAssertEqual(chat.model, "opus")
    }

    func testSessionBuildsTurnsAndKeepsBoxIdentityAcrossAppends() throws {
        let chat = session()
        chat.apply(try wire(ChatPatch(
            full: true, meta: meta(), turnOrder: ["t1"],
            turns: [turn("t1", seq: 1, items: ["u", "a"])],
            items: [upsert("u", .userMessage(.init(text: "hi")), status: .completed), upsert("a", .assistantMessage(text: "Hel"))]
        )))
        XCTAssertEqual(chat.turns.map(\.id), ["t1"])
        let turn1 = try XCTUnwrap(chat.turns.first)
        XCTAssertEqual(turn1.items.map(\.id), ["u", "a"])
        let answer = turn1.items[1]
        XCTAssertEqual(chat.activity, .working)

        chat.apply(try wire(ChatPatch(full: false, meta: nil, turnOrder: nil, turns: [], items: [
            .append(boxId: "a", kind: .assistantText, text: "lo"),
            .append(boxId: "a", kind: .assistantText, text: ", world"),
            .append(boxId: "missing", kind: .assistantText, text: "ignored"),
        ])))
        XCTAssertTrue(chat.turns.first === turn1, "turns keep their identity")
        XCTAssertTrue(chat.turns.first?.items[1] === answer, "boxes keep their identity")
        XCTAssertEqual(text(answer), "Hello, world")

        // The turn completes; an item is added and the order changes.
        chat.apply(try wire(ChatPatch(full: false, meta: nil, turnOrder: nil,
            turns: [turn("t1", seq: 1, status: "completed", items: ["u", "r", "a"])],
            items: [upsert("r", .reasoning(text: "thinking"), status: .completed)]
        )))
        XCTAssertEqual(turn1.status, .completed)
        XCTAssertEqual(turn1.items.map(\.id), ["u", "r", "a"])
        XCTAssertTrue(turn1.items[2] === answer)
        XCTAssertEqual(chat.activity, .idle)
    }

    func testSessionDropsTurnsLeftOutOfTheOrder() throws {
        let chat = session()
        chat.apply(try wire(ChatPatch(
            full: true, meta: meta(), turnOrder: ["t1", "t2"],
            turns: [turn("t1", seq: 1, status: "completed", items: ["a"]), turn("t2", seq: 2, status: "completed", items: ["b"])],
            items: [upsert("a", .assistantMessage(text: "one")), upsert("b", .assistantMessage(text: "two"))]
        )))
        XCTAssertEqual(chat.turns.map(\.id), ["t1", "t2"])
        // A revert drops t2.
        chat.apply(try wire(ChatPatch(full: false, meta: nil, turnOrder: ["t1"], turns: [], items: [])))
        XCTAssertEqual(chat.turns.map(\.id), ["t1"])
        // Its boxes went with it: an append for one changes nothing.
        chat.apply(try wire(ChatPatch(full: false, meta: nil, turnOrder: nil, turns: [], items: [.append(boxId: "b", kind: .assistantText, text: "!")])))
        // And a new turn reusing the id starts clean.
        chat.apply(try wire(ChatPatch(full: false, meta: nil, turnOrder: ["t1", "t2"],
            turns: [turn("t2", seq: 2, items: ["c"])],
            items: [upsert("c", .assistantMessage(text: "fresh"))]
        )))
        XCTAssertEqual(chat.turns.last?.items.map { text($0) }, ["fresh"])
    }

    func testAFullPatchReplacesTheMirror() throws {
        let chat = session()
        chat.apply(try wire(ChatPatch(
            full: true, meta: meta(), turnOrder: ["old"],
            turns: [turn("old", seq: 1, items: ["x"])], items: [upsert("x", .assistantMessage(text: "old"))]
        )))
        let old = try XCTUnwrap(chat.turns.first)
        // After a reconnect.
        chat.apply(try wire(ChatPatch(
            full: true, meta: meta(), turnOrder: ["new"],
            turns: [turn("new", seq: 1, status: "completed", items: ["y"])], items: [upsert("y", .assistantMessage(text: "new"))]
        )))
        XCTAssertEqual(chat.turns.map(\.id), ["new"])
        XCTAssertFalse(chat.turns.first === old)
        XCTAssertEqual(chat.turns.first?.items.map { text($0) }, ["new"])
    }

    func testSessionMetaDrivesRequestsAndBanner() throws {
        let chat = session()
        let request = AgentRequest(id: "r1", turnId: nil, itemId: nil, kind: .plan(text: "Plan"))
        chat.apply(try wire(ChatPatch(full: true, meta: meta(requests: [request], banner: "Revert failed"), turnOrder: [], turns: [], items: [])))
        XCTAssertEqual(chat.activity, .needsInput)
        XCTAssertEqual(chat.requests.map(\.id), ["r1"])
        XCTAssertEqual(chat.banner, "Revert failed")
        chat.apply(try wire(ChatPatch(full: false, meta: meta(), turnOrder: nil, turns: [], items: [])))
        XCTAssertNil(chat.banner)
        XCTAssertEqual(chat.activity, .idle)
    }

    func testSendingWhileDisconnectedKeepsTheDraft() {
        let chat = session()
        chat.send(text: "  keep me  ")
        XCTAssertEqual(chat.draft, "keep me")
        XCTAssertEqual(chat.banner, WireError.disconnected.message)
        // A blank message is simply not sent.
        chat.draft = ""
        chat.banner = nil
        chat.send(text: "   ")
        XCTAssertEqual(chat.draft, "")
        XCTAssertNil(chat.banner)
    }

    /// Engine → publisher → JSON → session: the mirror ends up matching.
    func testTheMirrorConvergesOnTheEngine() async throws {
        let chat = try await makeChat()
        let mirror = session()
        let publisher = ChatPublisher(chat: chat) { [unowned self] patch in
            mirror.apply(try! self.wire(patch))
        }
        publisher.start()
        defer { publisher.stop() }
        mirror.apply(try wire(publisher.fullPatch()))

        chat.send(text: "First")
        await eventually("first turn settles", timeout: 15) { chat.turns.first?.status == .failed }
        let turn = try XCTUnwrap(chat.turns.first)
        let box = ChatItemBox(id: "stream", item: AgentItem(id: "s", turnId: nil, status: .inProgress, content: .assistantMessage(text: "")))
        turn.items.append(box)
        for word in ["streaming ", "into ", "the ", "mirror"] {
            box.item.append(word, kind: .assistantText)
            try await Task.sleep(for: .milliseconds(20))
        }
        chat.setModel("sonnet", effort: "high")
        chat.send(text: "Second")

        func converged() -> Bool {
            guard mirror.turns.map(\.id) == chat.turns.map(\.id), mirror.title == chat.title,
                  mirror.model == chat.model, mirror.effort == chat.effort, mirror.connection == chat.connection else { return false }
            for (mine, theirs) in zip(mirror.turns, chat.turns) {
                guard mine.status == theirs.status, mine.items.map(\.id) == theirs.items.map(\.id),
                      mine.items.map(\.item) == theirs.items.map(\.item) else { return false }
            }
            return true
        }
        await eventually("mirror converges", timeout: 15) { chat.turns.count == 2 && chat.turns.last?.status == .failed && converged() }
        XCTAssertEqual(text(mirror.turns[0].items[1]), "streaming into the mirror")
    }
    #endif
}
