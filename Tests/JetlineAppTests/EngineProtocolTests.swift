import XCTest
@testable import JetlineApp

/// Drives a real `Engine` through `EngineServer` / `EngineClient` over a
/// socketpair — the exact path the Mac app and `jetlined` use — against a
/// throwaway git repository. Runs on macOS and Linux.
@MainActor
final class EngineProtocolTests: XCTestCase {
    nonisolated(unsafe) private static var dataDir: URL!

    override class func setUp() {
        super.setUp()
        // Before anything touches `Database.shared`: never the real ~/.jetline.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JETLINE_DATA_DIR", dir.path, 1)
        dataDir = dir
    }

    private var server: EngineServer!
    private var client: EngineClient!
    private var events: [EngineEvent] = []
    private var terminalBytes: [String: Data] = [:]

    override func setUp() async throws {
        let engine = Engine()
        server = EngineServer(engine: engine, engineVersion: "test")
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

    // MARK: Helpers

    private func git(_ args: [String], cwd: String) async throws {
        let result = await Subprocess.run(executable: "/usr/bin/env", args: ["git"] + args, cwd: cwd, env: [
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.com",
        ])
        XCTAssertTrue(result.success, "git \(args.joined(separator: " ")): \(result.stderr)")
    }

    private func makeRepo() async throws -> String {
        let dir = Self.dataDir.appendingPathComponent("repo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], cwd: dir.path)
        try await git(["config", "user.name", "Test User"], cwd: dir.path)
        try await git(["config", "user.email", "t@example.com"], cwd: dir.path)
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "."], cwd: dir.path)
        try await git(["commit", "-q", "-m", "init"], cwd: dir.path)
        return dir.path
    }

    /// Poll `condition` on the main actor until it holds or `timeout` passes.
    private func eventually(
        _ what: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func latestStatus(_ workspaceId: String) -> WorkspaceStatus? {
        for event in events.reversed() {
            if case let .workspaceStatus(id, status) = event, id == workspaceId { return status }
        }
        return nil
    }

    private func latestDiff(_ workspaceId: String) -> WorkspaceDiffState? {
        for event in events.reversed() {
            if case let .workspaceDiff(id, diff) = event, id == workspaceId { return diff }
        }
        return nil
    }

    private func latestGlobal() -> GlobalSnapshot? {
        for event in events.reversed() {
            if case let .global(snapshot) = event { return snapshot }
        }
        return nil
    }

    private func attachCollecting(_ terminalId: String) async throws {
        terminalBytes[terminalId] = Data()
        client.setTerminalHandler(terminalId) { [weak self] _, bytes in
            self?.terminalBytes[terminalId, default: Data()].append(bytes)
        }
        _ = try await client.call(API.AttachTerminal(terminalId: terminalId, fromOffset: nil))
    }

    private func text(_ terminalId: String) -> String {
        String(decoding: terminalBytes[terminalId] ?? Data(), as: UTF8.self)
    }

    // MARK: Tests

    func testHelloRejectsOtherProtocolVersions() async throws {
        do {
            _ = try await client.call(API.Hello(protocolVersion: Wire.protocolVersion + 1, clientName: "test"))
            XCTFail("expected a protocol mismatch")
        } catch let error as WireError {
            XCTAssertEqual(error.code, "protocolMismatch")
        }
    }

    func testRequestsBeforeHelloAreRefused() async throws {
        do {
            _ = try await client.call(API.SetFocus(workspaceId: nil))
            XCTFail("expected notReady")
        } catch let error as WireError {
            XCTAssertEqual(error.code, "notReady")
        }
    }

    func testWorkspaceLifecycleTerminalsAndDiffs() async throws {
        let hello = try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "test"))
        XCTAssertEqual(hello.engineVersion, "test")

        // Repository
        let repoPath = try await makeRepo()
        let repo = try await client.call(API.AddRepository(path: repoPath))
        XCTAssertEqual(repo.path, repoPath)
        await eventually("repo in global snapshot") { latestGlobal()?.repositories.contains { $0.id == repo.id } == true }

        do {
            _ = try await client.call(API.AddRepository(path: Self.dataDir.path))
            XCTFail("a non-repo should be refused")
        } catch let error as WireError {
            XCTAssertTrue(error.message.contains("Not a git repository"))
        }

        // Terminal-interface settings so activation opens a shell tab.
        var settings = try XCTUnwrap(latestGlobal()?.settings ?? hello.snapshot.global.settings)
        settings.agentInterface = .terminal
        settings.defaultAgent = .shell
        _ = try await client.call(API.SaveSettings(settings: settings))

        // Workspace with a run script.
        var withScripts = repo
        withScripts.runScript = "echo run-started; sleep 30"
        _ = try await client.call(API.UpdateRepository(repository: withScripts))
        let created = try await client.call(API.CreateWorkspace(repoId: repo.id, name: "Feature One"))
        guard case let .created(workspace) = created else { return XCTFail("expected a workspace, got \(created)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.worktreePath))
        XCTAssertTrue(workspace.branchName.contains("feature-one"), workspace.branchName)

        // Same branch again → the engine asks instead of clobbering.
        _ = try await client.call(API.SaveSettings(settings: settings))

        // Activate: a shell tab appears in the status.
        let activation = try await client.call(API.ActivateWorkspace(workspaceId: workspace.id, terminalSize: TerminalSize(cols: 100, rows: 30)))
        guard case .ready = activation else { return XCTFail("activation: \(activation)") }
        await eventually("a terminal tab") { latestStatus(workspace.id)?.terminals.count == 1 }
        let shell = try XCTUnwrap(latestStatus(workspace.id)?.terminals.first)
        XCTAssertEqual(shell.agent, .shell)

        // Terminal I/O round trip.
        try await attachCollecting(shell.id)
        client.sendTerminalInput(shell.id, Data("echo jetline-$((40+2))\n".utf8))
        await eventually("shell echo") { text(shell.id).contains("jetline-42") }

        // Re-attach from an offset replays only what came after it.
        let seen = UInt64(terminalBytes[shell.id]?.count ?? 0)
        var replay = Data()
        client.setTerminalHandler(shell.id) { _, bytes in replay.append(bytes) }
        let attach = try await client.call(API.AttachTerminal(terminalId: shell.id, fromOffset: seen))
        XCTAssertEqual(attach.replayFrom, seen)
        client.sendTerminalInput(shell.id, Data("echo second-$((1+1))\n".utf8))
        await eventually("second echo") { String(decoding: replay, as: UTF8.self).contains("second-2") }
        XCTAssertFalse(String(decoding: replay, as: UTF8.self).contains("jetline-42"), "replay repeated old output")

        // A second terminal, created explicitly, spawns at the given size.
        let second = try await client.call(API.CreateTerminal(
            workspaceId: workspace.id, agent: .shell, size: TerminalSize(cols: 77, rows: 21)
        ))
        try await attachCollecting(second.id)
        client.sendTerminalInput(second.id, Data("stty size\n".utf8))
        await eventually("stty size") { text(second.id).contains("21 77") }
        _ = try await client.call(API.CloseTerminal(terminalId: second.id))
        await eventually("closed terminal dropped") { latestStatus(workspace.id)?.terminals.count == 1 }

        // Run script: starts, streams, stops.
        _ = try await client.call(API.ToggleRun(workspaceId: workspace.id))
        await eventually("run starting") { latestStatus(workspace.id)?.run?.terminalId != nil }
        let runTerminal = try XCTUnwrap(latestStatus(workspace.id)?.run?.terminalId)
        try await attachCollecting(runTerminal)
        _ = try await client.call(API.ResizeTerminal(terminalId: runTerminal, size: TerminalSize(cols: 90, rows: 20)))
        await eventually("run output") { text(runTerminal).contains("run-started") }
        await eventually("run running", timeout: 5) { latestStatus(workspace.id)?.run?.phase == .running }
        _ = try await client.call(API.ToggleRun(workspaceId: workspace.id))
        await eventually("run stopped", timeout: 10) { latestStatus(workspace.id)?.run?.phase == .idle }
        let copied = try await client.call(API.TerminalText(terminalId: runTerminal))
        XCTAssertTrue(copied.contains("run-started"))

        // File watcher → diff refresh.
        try "new file\n".write(
            toFile: (workspace.worktreePath as NSString).appendingPathComponent("added.txt"),
            atomically: true, encoding: .utf8
        )
        await eventually("diff shows the new file", timeout: 15) {
            latestDiff(workspace.id)?.hasUncommitted == true
        }
        let files = try await client.call(API.ListFiles(cwd: workspace.worktreePath))
        XCTAssertTrue(files.contains("added.txt"))

        // Remote file browsing.
        let listing = try await client.call(API.ListDirectory(path: (repoPath as NSString).deletingLastPathComponent))
        XCTAssertTrue(listing.contains { $0.path == repoPath && $0.isGitRepo })

        // Uploads land on the engine's disk.
        let uploaded = try await client.call(API.UploadFile(name: "shot.png", data: Data([1, 2, 3])))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: uploaded)), Data([1, 2, 3]))
        let readBack = try await client.call(API.ReadFile(path: uploaded, maxBytes: 10))
        XCTAssertEqual(readBack, Data([1, 2, 3]))

        // Close the workspace: its terminals go, it stays in the sidebar.
        _ = try await client.call(API.CloseWorkspace(workspaceId: workspace.id))
        await eventually("closed") { latestStatus(workspace.id)?.isOpen == false && latestStatus(workspace.id)?.terminals.isEmpty == true }

        // Delete it: worktree gone, row gone.
        _ = try await client.call(API.DeleteWorkspace(workspaceId: workspace.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.worktreePath))
        await eventually("workspace row removed") {
            latestGlobal()?.workspacesByRepo[repo.id]?.contains { $0.id == workspace.id } == false
        }
    }

    func testBranchCollisionAsksBeforeOverriding() async throws {
        _ = try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "test"))
        let repoPath = try await makeRepo()
        var repo = try await client.call(API.AddRepository(path: repoPath))
        repo.addUniqueBranchSuffix = false
        repo.branchPrefixMode = BranchPrefixMode.none.rawValue
        _ = try await client.call(API.UpdateRepository(repository: repo))

        let first = try await client.call(API.CreateWorkspace(repoId: repo.id, name: "Clash"))
        guard case let .created(ws1) = first else { return XCTFail("\(first)") }
        let second = try await client.call(API.CreateWorkspace(repoId: repo.id, name: "Clash"))
        guard case let .branchInUse(branch, path, _) = second else { return XCTFail("expected branchInUse, got \(second)") }
        XCTAssertEqual(branch, "clash")
        XCTAssertEqual(path, ws1.worktreePath)

        let third = try await client.call(API.CreateWorkspace(repoId: repo.id, name: "Clash", overrideExisting: true))
        guard case let .created(ws3) = third else { return XCTFail("\(third)") }
        XCTAssertNotEqual(ws3.id, ws1.id)
        await eventually("old workspace dropped") {
            latestGlobal()?.workspacesByRepo[repo.id]?.map(\.id) == [ws3.id]
        }
    }

    func testChatPatchesStreamAppends() {
        var old = AgentItem(id: "a", turnId: "t", status: .inProgress, content: .assistantMessage(text: "Hello"))
        var new = old
        new.append(", world", kind: .assistantText)
        let suffix = new.streamedSuffix(since: old)
        XCTAssertEqual(suffix?.0, .assistantText)
        XCTAssertEqual(suffix?.1, ", world")

        old.status = .completed
        XCTAssertNil(new.streamedSuffix(since: old), "a status change isn't a pure append")
    }

    func testTerminalBufferKeepsOffsets() {
        let buffer = TerminalBuffer(capacity: 10)
        XCTAssertEqual(buffer.append(Data("hello".utf8)), 0)
        XCTAssertEqual(buffer.append(Data("world!!".utf8)), 5)
        // Trimmed to 75% of capacity: the oldest bytes fall out.
        let range = buffer.range
        XCTAssertEqual(range.end, 12)
        XCTAssertGreaterThan(range.start, 0)
        let all = buffer.read(from: nil)
        XCTAssertEqual(all.offset, range.start)
        let tail = buffer.read(from: 10)
        XCTAssertEqual(String(decoding: tail.bytes, as: UTF8.self), "!!")
        // Asking for trimmed bytes returns from the oldest retained.
        XCTAssertEqual(buffer.read(from: 0).offset, range.start)
    }
}
