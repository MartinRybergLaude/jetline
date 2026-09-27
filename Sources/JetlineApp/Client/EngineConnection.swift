import Foundation
import Observation

/// Where the app's engine runs.
enum EngineTarget: Codable, Equatable, Sendable {
    /// In this process (the default): Jetline as a plain Mac app.
    case local
    /// On another machine, reached by running `command` — normally
    /// `ssh -T <host> '~/.jetline/bin/jetlined attach'` — whose stdin/stdout
    /// carry the protocol.
    case remote(RemoteEngine)

    var isLocal: Bool { self == .local }

    var displayName: String {
        switch self {
        case .local: return "This Mac"
        case let .remote(remote): return remote.name
        }
    }
}

struct RemoteEngine: Codable, Equatable, Sendable {
    /// Shown in the UI ("devbox").
    var name: String
    /// Run through `/bin/sh -c`.
    var command: String
    /// The ssh destination, when the command is plain ssh — lets editors
    /// with ssh support open the engine's worktrees.
    var sshHost: String?

    static let defaultDaemonPath = "~/.jetline/bin/jetlined"

    /// The command for an ssh host alias or `user@host`.
    static func ssh(host: String, daemonPath: String = defaultDaemonPath) -> RemoteEngine {
        RemoteEngine(
            name: host,
            command: "ssh -T -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \(shellQuote(host)) \(shellQuote("\(daemonPath) attach"))",
            sshHost: host
        )
    }

    static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./@:~".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Owns the link to the engine: hosts the in-process one for `.local`,
/// spawns the remote command otherwise, and reconnects when a remote link
/// drops. `AppState` builds its mirror on `client` and resyncs on every
/// (re)connect via `onConnected`.
@MainActor
@Observable
final class EngineConnection {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        /// Lost the link; retrying.
        case reconnecting(attempt: Int, error: String?)
        /// Gave up (a local engine that couldn't start, a protocol mismatch).
        case failed(String)
    }

    private(set) var target: EngineTarget
    private(set) var status: Status = .idle
    private(set) var hello: API.HelloResult?
    @ObservationIgnored private(set) var client: EngineClient?

    /// The in-process engine, created on first use and kept for the app's
    /// life (switching to a remote host doesn't stop its agents).
    @ObservationIgnored private var localServer: EngineServer?
    @ObservationIgnored private var remoteProcess: Process?
    @ObservationIgnored private var remoteStderr = StderrTail()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// A fresh connection completed `hello`. Called on every reconnect.
    @ObservationIgnored var onConnected: ((EngineClient, API.HelloResult) -> Void)?
    /// The link dropped; the mirror should mark itself stale.
    @ObservationIgnored var onDisconnected: (() -> Void)?

    static let targetDefaultsKey = "JetlineEngineTarget"

    init(target: EngineTarget) {
        self.target = target
    }

    static func savedTarget() -> EngineTarget {
        if let override = ProcessInfo.processInfo.environment["JETLINE_REMOTE_COMMAND"], !override.isEmpty {
            return .remote(RemoteEngine(name: "remote", command: override))
        }
        guard let data = UserDefaults.standard.data(forKey: targetDefaultsKey),
              let target = try? JSONDecoder().decode(EngineTarget.self, from: data) else { return .local }
        return target
    }

    static func save(_ target: EngineTarget) {
        if let data = try? JSONEncoder().encode(target) {
            UserDefaults.standard.set(data, forKey: targetDefaultsKey)
        }
    }

    var isLocal: Bool { target.isLocal }

    var isConnected: Bool { status == .connected }

    /// The in-process engine, if one was ever started — it keeps running
    /// after a switch to a remote target, so app quit still has to stop it.
    var inProcessEngine: Engine? { localServer?.engine }

    // MARK: - Connecting

    func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        // Supersede any attempt in flight before starting another, so its
        // failure can't be mistaken for this one's and its link can't leak.
        generation += 1
        tearDownLink()
        status = .connecting
        let generation = self.generation
        Task { await attempt(attemptNumber: 0, generation: generation) }
    }

    /// Point at a different engine. The current link is dropped first.
    func switchTarget(_ target: EngineTarget) {
        guard target != self.target else { return }
        Self.save(target)
        tearDownLink()
        self.target = target
        hello = nil
        connect()
    }

    private func attempt(attemptNumber: Int, generation: Int) async {
        guard self.generation == generation else { return }
        if !target.isLocal {
            // The command runs with the login shell's PATH (a Finder launch
            // only has launchd's), so wait for it to resolve.
            _ = await LoginShellPath.get()
            guard self.generation == generation else { return }
        }
        do {
            let client = try makeClient()
            client.onClose = { [weak self] in
                guard let self, self.generation == generation else { return }
                self.linkDropped()
            }
            self.client = client
            client.start()
            let hello = try await client.call(API.Hello(protocolVersion: Wire.protocolVersion, clientName: "Jetline \(JetlineVersion.current)"))
            guard self.generation == generation else { return }
            self.hello = hello
            self.status = .connected
            onConnected?(client, hello)
        } catch {
            guard self.generation == generation else { return }
            let message = describe(error)
            tearDownLink()
            if let wire = error as? WireError, wire.code == "protocolMismatch" {
                status = .failed(message)
            } else if target.isLocal {
                status = .failed(message)
            } else {
                scheduleReconnect(attempt: attemptNumber + 1, error: message)
            }
        }
    }

    private func linkDropped() {
        let error = remoteStderr.text.nonBlank
        tearDownLink()
        onDisconnected?()
        if target.isLocal {
            status = .failed("The local engine stopped.")
        } else {
            scheduleReconnect(attempt: 1, error: error)
        }
    }

    private func scheduleReconnect(attempt: Int, error: String?) {
        status = .reconnecting(attempt: attempt, error: error)
        reconnectTask?.cancel()
        generation += 1
        let generation = self.generation
        let delay = min(15.0, pow(2.0, Double(min(attempt, 4))) / 2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.attempt(attemptNumber: attempt, generation: generation)
        }
    }

    /// Retry now instead of waiting out the backoff.
    func reconnectNow() {
        guard case .reconnecting = status else {
            if case .failed = status { connect() }
            return
        }
        connect()
    }

    private func tearDownLink() {
        client?.onClose = nil
        client?.close()
        client = nil
        if let process = remoteProcess, process.isRunning {
            process.terminate()
        }
        remoteProcess = nil
    }

    private func makeClient() throws -> EngineClient {
        switch target {
        case .local:
            let server = localServer ?? EngineServer(engine: Engine(), engineVersion: JetlineVersion.current)
            localServer = server
            guard let (a, b) = Sockets.pair() else { throw WireError("Couldn't create a local socket pair.") }
            server.accept(FramedConnection(readFD: a, writeFD: a, label: "local-server"))
            return EngineClient(connection: FramedConnection(readFD: b, writeFD: b, label: "local-client"))
        case let .remote(remote):
            return try spawnRemote(remote)
        }
    }

    private func spawnRemote(_ remote: RemoteEngine) throws -> EngineClient {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", remote.command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShellPath.snapshot()
        process.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let tail = StderrTail()
        remoteStderr = tail
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(data)
            }
        }
        try process.run()
        remoteProcess = process
        let readFD = dup(stdout.fileHandleForReading.fileDescriptor)
        let writeFD = dup(stdin.fileHandleForWriting.fileDescriptor)
        try? stdout.fileHandleForReading.close()
        try? stdin.fileHandleForWriting.close()
        let connection = FramedConnection(
            readFD: readFD,
            writeFD: writeFD,
            label: "remote",
            preamble: AttachPreamble.marker
        )
        return EngineClient(connection: connection)
    }

    private func describe(_ error: Error) -> String {
        let base = (error as? WireError)?.message ?? error.localizedDescription
        if let stderr = remoteStderr.text.nonBlank, (error as? WireError)?.code == "disconnected" {
            return stderr
        }
        return base
    }

    // MARK: - Convenience

    /// Call on the current link, failing fast when there is none.
    func call<R: RPC>(_ request: R) async throws -> R.Response {
        guard let client, status == .connected else { throw WireError.disconnected }
        return try await client.call(request)
    }

    func send<R: RPC>(_ request: R) {
        guard let client, status == .connected else { return }
        client.send(request)
    }
}

/// The last few KB of the remote command's stderr — the ssh or shell error
/// shown when the link can't be made.
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 4096 { data.removeFirst(data.count - 4096) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
