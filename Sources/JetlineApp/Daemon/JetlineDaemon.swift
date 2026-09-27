import Foundation
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
        case "version", "--version", "-v":
            print(JetlineVersion.current)
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
      version   Print the version.

    Data lives in ~/.jetline (override with JETLINE_DATA_DIR).
    """

    struct Options {
        var socketPath: String?

        mutating func parse(_ args: [String]) throws {
            var rest = args[...]
            while let arg = rest.popFirst() {
                switch arg {
                case "--socket":
                    guard let path = rest.popFirst() else { throw DaemonError("--socket needs a path") }
                    socketPath = path
                default:
                    throw DaemonError("unknown option '\(arg)'")
                }
            }
        }

        var socket: String {
            socketPath ?? Database.dataDirectory().appendingPathComponent("jetlined.sock").path
        }
    }

    struct DaemonError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

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
        try? FileManager.default.createDirectory(at: Database.dataDirectory(), withIntermediateDirectories: true)
        let socketPath = options.socket
        if let fd = Sockets.connect(path: socketPath) {
            close(fd)
            fail("already running (socket \(socketPath))")
        }
        let listener: Int32
        do {
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

            let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
            acceptSource.setEventHandler {
                guard let fd = Sockets.accept(listener) else { return }
                MainActor.assumeIsolated {
                    let connection = FramedConnection(readFD: fd, writeFD: fd, label: "client")
                    server.accept(connection)
                }
            }
            acceptSource.resume()
            DaemonRuntime.shared.sources.append(acceptSource)

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
        var argv = [executable] + serveCommandPrefix + ["serve"]
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
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        posix_spawnattr_setflags(&attributes, Int16(0x80 | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        #endif
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
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

    /// `jetline daemon serve` when running as the macOS app binary.
    private static var serveCommandPrefix: [String] {
        let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? ""
        return name == "jetlined" ? [] : (CommandLine.arguments.dropFirst().first == "daemon" ? ["daemon"] : [])
    }

    private static func currentExecutable() -> String? {
        #if os(Linux)
        if let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return path }
        #endif
        if let path = Bundle.main.executablePath { return path }
        return CommandLine.arguments.first
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
        while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
        print(kill(pid, 0) == 0 ? "still stopping (pid \(pid))" : "stopped")
        exit(0)
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
