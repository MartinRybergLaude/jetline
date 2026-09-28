import XCTest
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

/// The real `jetlined` binary from this build: its commands, `attach`
/// starting a background engine that outlives the bridge, and
/// `EngineConnection` driving it as a remote the way the Mac app does.
/// Every test gets its own data directory and stops its engine after.
@MainActor
final class DaemonTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    private var dataDir: String!
    private var binary: String!
    private var cleanups: [@MainActor () async -> Void] = []

    override func setUp() async throws {
        binary = try XCTUnwrap(Self.daemonBinary(), "jetlined isn't built next to the tests")
        // Short, so the socket fits in sockaddr_un.
        dataDir = "/tmp/jld-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
        _ = await run(["stop"])
        try? FileManager.default.removeItem(atPath: dataDir)
    }

    private static func daemonBinary() -> String? {
        var dirs: [URL] = []
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            dirs.append(bundle.bundleURL.deletingLastPathComponent())
        }
        #endif
        dirs.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        dirs.append(Bundle.main.bundleURL)
        return dirs.map { $0.appendingPathComponent("jetlined").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["JETLINE_DATA_DIR"] = dataDir
        env.removeValue(forKey: "SSH_AUTH_SOCK")
        return env
    }

    private struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Run `jetlined <args>` to completion.
    private func run(_ args: [String], env: [String: String]? = nil) async -> Result {
        let binary = self.binary!
        let environment = env ?? self.environment
        return await TestIO.background {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Result(status: -1, stdout: "", stderr: "couldn't run") }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }.value
    }

    /// `jetlined attach` as a subprocess, with an `EngineClient` on its
    /// stdin/stdout — what `ssh host jetlined attach` gives the app.
    private func attach(env: [String: String]? = nil, onEvent: @escaping (EngineEvent) -> Void = { _ in }) throws -> (Process, EngineClient) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["attach"]
        process.environment = env ?? environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let readFD = dup(stdout.fileHandleForReading.fileDescriptor)
        let writeFD = dup(stdin.fileHandleForWriting.fileDescriptor)
        try stdout.fileHandleForReading.close()
        try stdin.fileHandleForWriting.close()
        let client = EngineClient(connection: FramedConnection(
            readFD: readFD, writeFD: writeFD, label: "attach", preamble: AttachPreamble.marker
        ))
        client.onEvent = onEvent
        client.start()
        cleanups.append {
            client.close()
            if process.isRunning { process.terminate() }
        }
        return (process, client)
    }

    private func hello(_ client: EngineClient) async throws -> API.HelloResult {
        try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "daemon-test"))
    }

    // MARK: Commands

    func testVersionInfoAndHelp() async throws {
        let version = await run(["version"])
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), JetlineVersion.embedded)

        let info = await run(["info"])
        XCTAssertEqual(info.status, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, JetlineVersion.embedded)
        XCTAssertEqual(object["protocol"] as? Int, Wire.protocolVersion)
        XCTAssertEqual(object["features"] as? [String], API.features)

        let help = await run(["help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("attach"))
        let bare = await run([])
        XCTAssertEqual(bare.stdout, help.stdout, "no command is help")
    }

    func testBadArgumentsFail() async {
        let unknown = await run(["frobnicate"])
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.stderr.contains("unknown command 'frobnicate'"), unknown.stderr)

        let missing = await run(["status", "--socket"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.stderr.contains("--socket needs a path"), missing.stderr)

        let flag = await run(["status", "--verbose"])
        XCTAssertEqual(flag.status, 1)
        XCTAssertTrue(flag.stderr.contains("unknown option '--verbose'"), flag.stderr)

        let rpc = await run(["rpc"])
        XCTAssertEqual(rpc.status, 1)
    }

    func testStatusStopAndRpcWithNothingRunning() async {
        let status = await run(["status"])
        XCTAssertEqual(status.status, 3)
        XCTAssertEqual(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "not running")
        let stop = await run(["stop"])
        XCTAssertEqual(stop.status, 0)
        XCTAssertTrue(stop.stdout.contains("not running"))
        let rpc = await run(["rpc", "session.focus"])
        XCTAssertEqual(rpc.status, 1)
        XCTAssertTrue(rpc.stderr.contains("not running"), rpc.stderr)
    }

    // MARK: attach / serve

    func testAttachStartsAnEngineThatOutlivesTheBridge() async throws {
        let (first, client) = try attach()
        let hello = try await hello(client)
        XCTAssertEqual(hello.engineVersion, JetlineVersion.embedded)
        XCTAssertEqual(hello.dataDirectory, dataDir)
        XCTAssertEqual(hello.features, API.features)
        XCTAssertEqual(hello.platform, Platform.name)

        let repoPath = try await TestSupport.makeRepo()
        let repo = try await client.call(API.AddRepository(path: repoPath))
        let terminal = try await client.call(API.CreateTerminal(
            workspaceId: Engine.repositoryBaseWorkspacePrefix + repo.id, agent: .shell, size: TerminalSize(cols: 80, rows: 24)
        ))
        var output = ""
        client.setTerminalHandler(terminal.id) { _, bytes in output += String(decoding: bytes, as: UTF8.self) }
        _ = try await client.call(API.AttachTerminal(terminalId: terminal.id, fromOffset: nil))
        client.sendTerminalInput(terminal.id, Data("echo before-$((5*5))\n".utf8))
        await eventually("shell output") { output.contains("before-25") }

        let status = await run(["status"])
        XCTAssertEqual(status.status, 0)
        XCTAssertTrue(status.stdout.contains("running (pid"), status.stdout)
        let pid = try String(contentsOfFile: "\(dataDir!)/jetlined.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(status.stdout.contains(pid))

        // Drop the bridge, as a laptop closing its lid would.
        client.close()
        await eventually("bridge exits", timeout: 10) { !first.isRunning }

        // The engine kept the repository and the shell.
        let (_, again) = try attach()
        let second = try await self.hello(again)
        XCTAssertTrue(second.snapshot.global.repositories.contains { $0.id == repo.id })
        XCTAssertTrue(second.snapshot.statuses.values.contains { $0.terminals.contains { $0.id == terminal.id } }, "the shell is still running")
        var replay = ""
        again.setTerminalHandler(terminal.id) { _, bytes in replay += String(decoding: bytes, as: UTF8.self) }
        _ = try await again.call(API.AttachTerminal(terminalId: terminal.id, fromOffset: nil))
        await eventually("replayed output") { replay.contains("before-25") }

        // rpc talks to the same engine.
        let rpc = await run(["rpc", "terminal.text", #"{"terminalId":"\#(terminal.id)"}"#])
        XCTAssertEqual(rpc.status, 0, rpc.stderr)
        XCTAssertTrue(rpc.stdout.contains("before-25"))
        let bad = await run(["rpc", "no.such.method"])
        XCTAssertEqual(bad.status, 1)
        XCTAssertTrue(bad.stderr.contains("Unknown method"), bad.stderr)

        let stop = await run(["stop"])
        XCTAssertEqual(stop.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "stopped")
        let after = await run(["status"])
        XCTAssertEqual(after.status, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dataDir!)/jetlined.sock"), "the socket goes with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dataDir!)/jetlined.pid"))
    }

    func testConcurrentAttachesShareOneEngine() async throws {
        let clients = try (0..<4).map { _ in try attach().1 }
        var hellos: [API.HelloResult] = []
        for client in clients { hellos.append(try await hello(client)) }
        XCTAssertEqual(hellos.count, 4)
        // One engine: a repo added through one connection shows up for all.
        let repo = try await clients[0].call(API.AddRepository(path: try await TestSupport.makeRepo()))
        for client in clients.dropFirst() {
            let snapshot = try await hello(client).snapshot
            XCTAssertTrue(snapshot.global.repositories.contains { $0.id == repo.id })
        }
        let log = (try? String(contentsOfFile: "\(dataDir!)/jetlined.log", encoding: .utf8)) ?? ""
        XCTAssertEqual(log.components(separatedBy: "serving on").count - 1, 1, "exactly one engine started:\n\(log)")
    }

    func testASecondServeRefusesToStart() async throws {
        let (_, client) = try attach()
        _ = try await hello(client)
        let second = await run(["serve"])
        XCTAssertEqual(second.status, 1)
        XCTAssertTrue(second.stderr.contains("already running"), second.stderr)
        // And didn't take the socket from the first.
        _ = try await client.call(API.SetFocus(workspaceId: nil))
        let status = await run(["status"])
        XCTAssertEqual(status.status, 0)
    }

    func testTheDataDirectoryIsPrivate() async throws {
        let (_, client) = try attach()
        _ = try await hello(client)
        var st = stat()
        XCTAssertEqual(stat(dataDir, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(stat("\(dataDir!)/jetlined.sock", &st), 0)
        XCTAssertEqual(st.st_mode & 0o077, 0, "nobody else can connect")
    }

    func testALongDataDirectoryGetsASocketInAPrivateTmpDirectory() async throws {
        let long = TestSupport.dataDir.appendingPathComponent("daemon-" + String(repeating: "x", count: 80) + "-\(UUID().uuidString.prefix(6))").path
        XCTAssertGreaterThan(long.utf8.count, 100)
        var env = environment
        env["JETLINE_DATA_DIR"] = long
        cleanups.append { [unowned self] in _ = await self.run(["stop"], env: env) }
        let (_, client) = try attach(env: env)
        _ = try await hello(client)
        let status = await run(["status"], env: env)
        XCTAssertEqual(status.status, 0, status.stdout + status.stderr)
        let privateDir = "/tmp/jetlined-\(getuid())/"
        XCTAssertTrue(status.stdout.contains("socket \(privateDir)"), status.stdout)
        var st = stat()
        XCTAssertEqual(lstat(privateDir, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(st.st_uid, getuid())

        // Stable: the same data directory always maps to the same socket.
        let again = await run(["status"], env: env)
        XCTAssertEqual(again.stdout, status.stdout)
    }

    func testAnExplicitSocketPath() async throws {
        let socket = "/tmp/jls-\(UUID().uuidString.prefix(6)).sock"
        defer { unlink(socket) }
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve", "--socket", socket]
        serve.environment = environment
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        cleanups.append { if serve.isRunning { serve.terminate() }; serve.waitUntilExit() }
        await eventually("listening", timeout: 10) { FileManager.default.fileExists(atPath: socket) }
        let status = await run(["status", "--socket", socket])
        XCTAssertEqual(status.status, 0, status.stdout)
        XCTAssertTrue(status.stdout.contains(socket))
        let defaultStatus = await run(["status"])
        XCTAssertEqual(defaultStatus.status, 3, "not on the default socket")
        // Answering requests means it's past setup (signal handlers included).
        let rpc = await run(["rpc", "session.focus", "--socket", socket])
        XCTAssertEqual(rpc.status, 0, rpc.stderr)

        // SIGTERM: a clean stop that removes the socket.
        serve.terminate()
        await eventually("exits", timeout: 10) { !serve.isRunning }
        XCTAssertEqual(serve.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    // MARK: EngineConnection over a remote command

    private func remoteCommand(prefix: String = "", env extra: String = "") -> String {
        "\(prefix)JETLINE_DATA_DIR=\(RemoteEngine.shellQuote(dataDir)) \(extra)exec \(RemoteEngine.shellQuote(binary)) attach"
    }

    func testEngineConnectionConnectsThroughALoginBannerAndReconnects() async throws {
        // A chatty login shell prints before the daemon starts.
        let command = remoteCommand(prefix: "echo 'Welcome to devbox'; printf '\\0\\0\\0\\5garbage'; ")
        let connection = EngineConnection(target: .remote(RemoteEngine(name: "devbox", command: command)))
        var connects: [API.HelloResult] = []
        var drops = 0
        connection.onConnected = { _, hello in connects.append(hello) }
        connection.onDisconnected = { drops += 1 }
        cleanups.append { connection.disconnect() }
        connection.connect()
        XCTAssertEqual(connection.status, .connecting)
        await eventually("connected", timeout: 20) { connection.status == .connected }
        XCTAssertEqual(connects.count, 1)
        XCTAssertEqual(connection.hello?.dataDirectory, dataDir)
        XCTAssertFalse(connection.isLocal)

        let repo = try await connection.call(API.AddRepository(path: try await TestSupport.makeRepo()))

        // The engine dies under it: the link drops and comes back.
        let stop = await run(["stop"])
        XCTAssertEqual(stop.status, 0)
        await eventually("dropped", timeout: 10) { drops == 1 }
        if case .reconnecting = connection.status {} else if connection.status != .connected {
            XCTFail("expected reconnecting, got \(connection.status)")
        }
        await eventually("reconnected", timeout: 30) { connection.status == .connected && connects.count == 2 }
        // `attach` started a fresh engine, which loaded the saved state.
        XCTAssertTrue(connects[1].snapshot.global.repositories.contains { $0.id == repo.id })

        connection.disconnect()
        XCTAssertEqual(connection.status, .idle)
        do {
            _ = try await connection.call(API.SetFocus(workspaceId: nil))
            XCTFail("expected disconnected")
        } catch let error as WireError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    func testAFailingRemoteCommandReportsItsStderrAndRetries() async throws {
        let connection = EngineConnection(target: .remote(RemoteEngine(
            name: "broken", command: "echo 'ssh: Could not resolve hostname nowhere' >&2; exit 255"
        )))
        cleanups.append { connection.disconnect() }
        connection.connect()
        await eventually("reconnecting with the error", timeout: 20) {
            if case let .reconnecting(_, error) = connection.status { return error?.contains("Could not resolve hostname") == true }
            return false
        }
        // Retargeting at a working command connects.
        connection.retarget(.remote(RemoteEngine(name: "fixed", command: remoteCommand())))
        await eventually("connected", timeout: 20) { connection.status == .connected }
        XCTAssertEqual(connection.target.displayName, "fixed")
    }

    /// A remote that keeps failing before `hello` is retried with a
    /// growing delay, not once a second forever.
    func testBackoffGrowsWhileTheRemoteKeepsFailing() async throws {
        let connection = EngineConnection(target: .remote(RemoteEngine(name: "down", command: "echo down >&2; exit 1")))
        cleanups.append { connection.disconnect() }
        connection.connect()
        await eventually("third attempt", timeout: 20) {
            if case let .reconnecting(attempt, _) = connection.status { return attempt >= 3 } else { return false }
        }
    }

    func testReconnectNowRetriesAtOnce() async throws {
        let flag = "\(dataDir!)-ready"
        defer { unlink(flag) }
        // Fails until the flag file exists.
        let command = "[ -e \(RemoteEngine.shellQuote(flag)) ] || { echo not yet >&2; exit 1; }; " + remoteCommand()
        let connection = EngineConnection(target: .remote(RemoteEngine(name: "later", command: command)))
        cleanups.append { connection.disconnect() }
        connection.connect()
        await eventually("reconnecting", timeout: 20) {
            if case let .reconnecting(_, error) = connection.status { return error == "not yet" } else { return false }
        }
        FileManager.default.createFile(atPath: flag, contents: nil)
        connection.reconnectNow()
        await eventually("connected", timeout: 10) { connection.status == .connected }
    }
}
