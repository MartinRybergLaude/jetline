import Foundation
import CJetlineSys
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The headless daemon: `jetlined` on Linux, `jetline daemon` on macOS.
///
///     jetlined serve      run the engine, listening on a unix socket
///     jetlined attach     bridge stdin/stdout to the running engine,
///                         starting it first if needed — what the Mac app
///                         runs over `ssh host jetlined attach`
///     jetlined status     is it running?
///     jetlined stop       stop it (and every agent / terminal it runs)
///     jetlined version
///
/// The engine outlives any one connection: closing the laptop (or losing
/// the network) drops the `attach` bridge, not the agents.
public enum JetlineDaemon {
    public static func run(arguments: [String]) -> Never {
        var args = arguments
        let command = args.isEmpty ? "help" : args.removeFirst()
        var options = Options()
        do {
            try options.parse(args)
        } catch {
            fail("\(error)")
        }
        switch command {
        case "serve":
            serve(options)
        case "attach":
            attach(options)
        case "status":
            status(options)
        case "stop":
            stop(options)
        case "rpc":
            rpc(options)
        case "mcp":
            AgentToolsServer.run()
        case "version", "--version", "-v":
            print(JetlineVersion.current)
            exit(0)
        case "info":
            // Machine-readable, for the app's installer check.
            let features = API.features.map { "\"\($0)\"" }.joined(separator: ",")
            print(#"{"version":"\#(JetlineVersion.current)","protocol":\#(Wire.protocolVersion),"features":[\#(features)]}"#)
            exit(0)
        case "help", "--help", "-h":
            print(usage)
            exit(0)
        default:
            fail("unknown command '\(command)'\n\n\(usage)")
        }
    }

    static let usage = """
    usage: jetlined <command> [--socket PATH]

    commands:
      serve     Run the Jetline engine in the foreground, listening on a unix socket.
      attach    Connect stdin/stdout to the engine, starting it in the background
                first if it isn't running. The Jetline app runs this over ssh.
      status    Report whether the engine is running.
      stop      Stop the engine and everything it runs.
      rpc METHOD [JSON]
                Send one request to the running engine and print the reply
                (for scripting and debugging; methods are in Protocol/API.swift).
      mcp       Serve Jetline's agent tools over MCP on stdin/stdout. Jetline
                starts this for the agents it launches.
      version   Print the version.
      info      Print version and protocol as JSON.

    Data lives in ~/.jetline (override with JETLINE_DATA_DIR).
    """

    struct Options {
        var socketPath: String?
        var positional: [String] = []

        mutating func parse(_ args: [String]) throws {
            var rest = args[...]
            while let arg = rest.popFirst() {
                switch arg {
                case "--socket":
                    guard let path = rest.popFirst() else { throw DaemonError("--socket needs a path") }
                    socketPath = path
                case let flag where flag.hasPrefix("--"):
                    throw DaemonError("unknown option '\(flag)'")
                default:
                    positional.append(arg)
                }
            }
        }

        var socket: String {
            socketPath ?? JetlineDaemon.socketPath(named: "jetlined")
        }
    }

    /// `<data dir>/<name>.sock`, or a short stable path in a private /tmp
    /// directory when that would be too long for a unix socket.
    static func socketPath(named name: String) -> String {
        let dataDir = Database.dataDirectory().path
        let preferred = (dataDir as NSString).appendingPathComponent("\(name).sock")
        // sockaddr_un caps the path at 104 bytes (macOS) / 108 (Linux).
        // A long data dir gets a short, stable path in /tmp instead.
        guard preferred.utf8.count >= 100 else { return preferred }
        // The daemon's hash covers the data dir alone, as it always has, so
        // a running older daemon is still found.
        var hash: UInt64 = 1469598103934665603
        for byte in (name == "jetlined" ? dataDir : dataDir + "/" + name).utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        // In a private directory: a predictable name straight in /tmp
        // could be squatted by another user.
        let dir = JetlineDaemon.privateTempDirectory()
        return "\(dir)/\(String(hash, radix: 16)).sock"
    }

    struct DaemonError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// `/tmp/jetlined-<uid>`, created 0700 and verified to be ours (not a
    /// symlink, not someone else's).
    static func privateTempDirectory() -> String {
        let dir = "/tmp/jetlined-\(getuid())"
        mkdir(dir, 0o700)
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            fail("\(dir) isn't a directory owned by you; remove it or set JETLINE_DATA_DIR to a shorter path")
        }
        if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
        return dir
    }

    /// `~/.jetline` holds the database, logs, uploads and the socket: keep it
    /// private on a shared host.
    private static func prepareDataDirectory() {
        let dir = Database.dataDirectory().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
    }

    static var lockFile: String { Database.dataDirectory().appendingPathComponent("jetlined.lock").path }
    static var agentSocketLink: String { Database.dataDirectory().appendingPathComponent("ssh-agent.sock").path }

    static var pidFile: String { Database.dataDirectory().appendingPathComponent("jetlined.pid").path }
    static var logFile: String { Database.dataDirectory().appendingPathComponent("jetlined.log").path }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("jetlined: \(message)\n".utf8))
        exit(1)
    }

    private static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - serve

    private static func serve(_ options: Options) -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        prepareDataDirectory()
        // One engine per data directory, held for the process's life: two
        // racing `attach`es would otherwise both start one, and the second
        // would take the socket from the first.
        let lock = open(lockFile, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            fail("already running (\(lockFile) is locked)")
        }
        // Held (never closed) for the process's life.
        _ = lock
        let socketPath = options.socket
        let listener: Int32
        do {
            let previous = umask(0o077)
            defer { umask(previous) }
            listener = try Sockets.listen(path: socketPath)
        } catch {
            fail("can't listen on \(socketPath): \(error)")
        }
        try? "\(getpid())\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        log("jetlined \(JetlineVersion.current) serving on \(socketPath) (pid \(getpid()))")

        MainActor.assumeIsolated {
            let engine = Engine()
            let server = EngineServer(engine: engine, engineVersion: JetlineVersion.current)
            server.onClientCountChanged = { count in log("clients: \(count)") }
            DaemonRuntime.shared.server = server
            server.accept(onListener: listener)
            // Agents this engine launches reach it on the same socket.
            engine.agentToolsSocket = socketPath

            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    MainActor.assumeIsolated {
                        log("stopping (signal \(sig))")
                        unlink(socketPath)
                        Task { @MainActor in
                            await engine.shutdown()
                            try? FileManager.default.removeItem(atPath: pidFile)
                            exit(0)
                        }
                    }
                }
                source.resume()
                DaemonRuntime.shared.sources.append(source)
            }
        }
        dispatchMain()
    }

    // MARK: - attach

    private static func attach(_ options: Options) -> Never {
        signal(SIGPIPE, SIG_IGN)
        prepareDataDirectory()
        // Point the engine's stable agent socket at this session's forwarded
        // agent (if any): the engine outlives the ssh session that started
        // it, and git over ssh would otherwise hold a dead socket path.
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !agent.isEmpty, agent != agentSocketLink {
            unlink(agentSocketLink)
            symlink(agent, agentSocketLink)
        }
        let socketPath = options.socket
        var fd = Sockets.connect(path: socketPath)
        if fd == nil {
            startBackgroundServer(options)
            let deadline = Date().addingTimeInterval(15)
            while fd == nil, Date() < deadline {
                usleep(100_000)
                fd = Sockets.connect(path: socketPath)
            }
        }
        guard let fd else {
            fail("the engine didn't start; see \(logFile)")
        }
        // Mark where the byte stream starts, so the client can skip anything
        // a login script printed before us.
        _ = writeAll(fd: STDOUT_FILENO, AttachPreamble.marker)
        // Two blocking pumps; whichever side hangs up ends the bridge. The
        // engine carries on without us.
        let upstream = Thread {
            relay(from: STDIN_FILENO, to: fd)
            shutdown(fd, Int32(SHUT_WR))
        }
        upstream.start()
        relay(from: fd, to: STDOUT_FILENO)
        exit(0)
    }

    private static func relay(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = read(source, &buffer, buffer.count)
            if n > 0 {
                let failed = buffer.withUnsafeBytes { raw in
                    writeAll(fd: destination, raw.baseAddress!, count: n) != nil
                }
                if failed { return }
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    /// Launch `serve` detached from this session (its own session, output to
    /// the log file), so it survives the ssh connection that started it.
    private static func startBackgroundServer(_ options: Options) {
        try? FileManager.default.createDirectory(at: Database.dataDirectory(), withIntermediateDirectories: true)
        guard let executable = currentExecutable() else { fail("can't locate my own executable") }
        var argv = [executable] + commandPrefix + ["serve"]
        if let socket = options.socketPath { argv += ["--socket", socket] }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logFile, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        #else
        jl_spawn_addclosefrom(&actions, 3)
        posix_spawnattr_setflags(&attributes, Int16(jl_spawn_setsid_flag()) | Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        #endif
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        var environment = ProcessInfo.processInfo.environment
        // Session-specific ssh variables would go stale when this session
        // ends; the agent goes through the link `attach` keeps current.
        for key in ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"] { environment.removeValue(forKey: key) }
        if environment["SSH_AUTH_SOCK"] != nil { environment["SSH_AUTH_SOCK"] = agentSocketLink }
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        let result = cArgs.withUnsafeBufferPointer { argvPtr in
            cEnv.withUnsafeBufferPointer { envPtr in
                posix_spawn(&pid, executable, &actions, &attributes, argvPtr.baseAddress!, envPtr.baseAddress!)
            }
        }
        if result != 0 {
            fail("couldn't start the engine: \(String(cString: strerror(result)))")
        }
    }

    /// What precedes a daemon command when running this binary: nothing
    /// for `jetlined`; the macOS app binary sets `daemon` (`jetline daemon …`).
    /// Set by the entry point rather than guessed from the executable's
    /// name, which a renamed install would get wrong.
    nonisolated(unsafe) public static var commandPrefix: [String] = []

    static func currentExecutable() -> String? {
        #if os(Linux)
        if let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return path }
        #endif
        if let path = Bundle.main.executablePath { return path }
        return CommandLine.arguments.first
    }

    // MARK: - rpc

    private static func rpc(_ options: Options) -> Never {
        guard let method = options.positional.first else { fail("usage: jetlined rpc METHOD [JSON]") }
        let paramsJSON = options.positional.dropFirst().first ?? "{}"
        guard let params = try? JSONValue.parse(Data(paramsJSON.utf8)) else { fail("params aren't valid JSON") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { fail("no reply after 60s") }
        do {
            let client = try BlockingEngineClient(socketPath: options.socket, clientName: "jetlined rpc")
            print(try client.call(method, params).prettyPrinted())
            exit(0)
        } catch let error as WireError where error.code == "notRunning" {
            fail("not running")
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - status / stop

    private static func status(_ options: Options) -> Never {
        if let fd = Sockets.connect(path: options.socket) {
            close(fd)
            let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            print("running (pid \(pid), socket \(options.socket))")
            exit(0)
        }
        print("not running")
        exit(3)
    }

    private static func stop(_ options: Options) -> Never {
        guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            print("not running")
            exit(0)
        }
        guard kill(pid, SIGTERM) == 0 else {
            try? FileManager.default.removeItem(atPath: pidFile)
            print("not running")
            exit(0)
        }
        let deadline = Date().addingTimeInterval(10)
        while isAlive(pid), Date() < deadline { usleep(100_000) }
        print(isAlive(pid) ? "still stopping (pid \(pid))" : "stopped")
        exit(0)
    }

    /// Running, as opposed to gone or exited-but-unreaped: in a container
    /// whose PID 1 doesn't reap orphans, the stopped daemon lingers as a
    /// zombie that still answers `kill(pid, 0)`.
    private static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        #if os(Linux)
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")") {
            let state = stat[stat.index(after: close)...].split(separator: " ").first
            if state == "Z" || state == "X" { return false }
        }
        #endif
        return true
    }
}

/// Keeps the serving objects alive for the life of the process.
@MainActor
final class DaemonRuntime {
    static let shared = DaemonRuntime()
    var server: EngineServer?
    nonisolated(unsafe) var sources: [DispatchSourceProtocol] = []
}

enum JetlineVersion {
    /// The app's bundle version where there is a bundle; the build's
    /// embedded version otherwise (the Linux daemon).
    static var current: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return embedded
    }

    /// Kept in step with `BundleResources/Info.plist` by `scripts/bump-version.sh`.
    static let embedded = "0.7.1"
}
