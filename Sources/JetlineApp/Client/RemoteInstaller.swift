#if os(macOS)
import Foundation

/// Sets up a remote machine over plain ssh: looks at what's there (OS,
/// architecture, an installed `jetlined` and its version, the tools the
/// engine drives) and installs or updates `jetlined` by streaming the
/// binary over the same ssh — no scp, no checkout, no Docker on the Mac.
///
/// ssh runs non-interactively (`BatchMode`): key-based auth is required, and
/// a host key seen for the first time is accepted and remembered, like a
/// first `ssh` would after "yes".
enum RemoteInstaller {
    struct Probe: Equatable {
        enum OS: Equatable { case linux, macOS, other(String) }
        var os: OS
        /// `x86_64` or `aarch64` (normalized).
        var arch: String
        /// Version of the `jetlined` at the configured path, if any.
        var daemonVersion: String?
        /// Its protocol version (`jetlined info`; nil for older daemons).
        var daemonProtocol: Int?
        /// Its optional capabilities (`jetlined info`; nil for older daemons).
        var daemonFeatures: [String]? = nil
        var daemonRunning: Bool
        /// A Jetline.app on a Mac host, whose `jetline daemon` can serve.
        var macAppDaemon: String?
        /// Of git, gh, claude, codex: the ones the login shell can't find.
        var missingTools: [String]

        var isInstalled: Bool { daemonVersion != nil }

        /// Compatible with this app (same protocol).
        var isCompatible: Bool {
            guard isInstalled else { return false }
            if let daemonProtocol { return daemonProtocol == Wire.protocolVersion }
            return daemonVersion == JetlineVersion.current
        }

        /// This app's version, able to do everything this app's engine can —
        /// a build of the same version that lacks a feature is outdated.
        /// (A Mac's app daemon reports no features; its version stands.)
        var isCurrent: Bool {
            daemonVersion == JetlineVersion.current
                && (daemonFeatures.map { Set(API.features).isSubset(of: $0) } ?? (os != .linux))
        }
    }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The Jetline.app daemon command on a Mac host.
    static let macDaemonCommand = "/Applications/Jetline.app/Contents/MacOS/jetline daemon"

    // MARK: - Probe

    static func probe(host: String, daemonPath: String) async throws -> Probe {
        let path = remotePathExpression(daemonPath)
        let script = """
        echo "os=$(uname -s)"
        echo "arch=$(uname -m)"
        p=\(path)
        if [ -x "$p" ]; then
          echo "version=$("$p" version 2>/dev/null)"
          echo "info=$("$p" info 2>/dev/null)"
          "$p" status >/dev/null 2>&1 && echo "running=1"
        fi
        if [ -x /Applications/Jetline.app/Contents/MacOS/jetline ]; then
          echo "macapp=1"
          echo "macversion=$(/Applications/Jetline.app/Contents/MacOS/jetline daemon version 2>/dev/null)"
        fi
        for t in git gh claude codex; do
          "${SHELL:-/bin/sh}" -lc "command -v $t" >/dev/null 2>&1 </dev/null || echo "missing=$t"
        done
        """
        let result = try await ssh(host: host, command: "sh -c \(RemoteEngine.shellQuote(script))", stdin: nil)
        guard result.status == 0 else { throw Failure(message: explain(result.stderr, status: result.status)) }
        var fields: [String: [String]] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq]), default: []].append(String(line[line.index(after: eq)...]))
        }
        let osName = fields["os"]?.first ?? ""
        let os: Probe.OS = osName == "Linux" ? .linux : osName == "Darwin" ? .macOS : .other(osName)
        var protocolVersion: Int?
        var features: [String]?
        if let info = fields["info"]?.first, let data = info.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            protocolVersion = object["protocol"] as? Int
            features = object["features"] as? [String]
        }
        var version = fields["version"]?.first?.trimmingCharacters(in: .whitespaces).nonBlank
        if os == .macOS, version == nil, daemonPath.contains("Jetline.app") {
            version = fields["macversion"]?.first?.trimmingCharacters(in: .whitespaces).nonBlank
        }
        return Probe(
            os: os,
            arch: normalize(arch: fields["arch"]?.first ?? ""),
            daemonVersion: version,
            daemonProtocol: protocolVersion,
            daemonFeatures: features,
            daemonRunning: fields["running"] != nil,
            macAppDaemon: fields["macapp"] != nil ? macDaemonCommand : nil,
            missingTools: fields["missing"] ?? []
        )
    }

    // MARK: - Install

    /// Put this app's `jetlined` for `arch` at `daemonPath` on `host`.
    /// Replaces the file atomically; a running engine keeps the old version
    /// until it restarts (see `restartEngine`).
    static func install(
        host: String,
        daemonPath: String,
        arch: String,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        let gz = try await DaemonBinaries.gzippedBinary(arch: arch, progress: progress)
        await progress("Uploading to \(host)…")
        let path = remotePathExpression(daemonPath)
        let script = """
        set -e
        p=\(path)
        mkdir -p "$(dirname "$p")"
        gunzip -c > "$p.new"
        chmod +x "$p.new"
        mv -f "$p.new" "$p"
        "$p" version
        """
        let result = try await ssh(host: host, command: "sh -c \(RemoteEngine.shellQuote(script))", stdin: gz)
        guard result.status == 0 else { throw Failure(message: explain(result.stderr, status: result.status)) }
        await progress("Installed jetlined \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).")
    }

    /// Stop the running engine so the next connection starts the installed
    /// version. Ends every agent and terminal it runs.
    static func restartEngine(host: String, daemonPath: String) async throws {
        let path = remotePathExpression(daemonPath)
        let result = try await ssh(host: host, command: "sh -c \(RemoteEngine.shellQuote("p=\(path); \"$p\" stop"))", stdin: nil)
        guard result.status == 0 else { throw Failure(message: explain(result.stderr, status: result.status)) }
    }

    // MARK: - Helpers

    /// A shell expression for `path` on the remote: `~/x` → `"$HOME/x"`,
    /// anything else single-quoted.
    static func remotePathExpression(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            return "\"$HOME\"/" + RemoteEngine.shellQuote(rest)
        }
        return RemoteEngine.shellQuote(trimmed)
    }

    static func normalize(arch: String) -> String {
        switch arch.trimmingCharacters(in: .whitespaces) {
        case "x86_64", "amd64": return "x86_64"
        case "aarch64", "arm64": return "aarch64"
        default: return arch
        }
    }

    /// Turn ssh's stderr into something to act on.
    static func explain(_ stderr: String, status: Int32) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Permission denied") {
            return "ssh couldn't log in without a password. Jetline needs key-based ssh access (ssh-copy-id, or your ssh agent). (\(text))"
        }
        if text.contains("Could not resolve hostname") || text.contains("Name or service not known") {
            return "Unknown host. Use a name from ~/.ssh/config, or user@hostname. (\(text))"
        }
        if text.contains("Connection refused") || text.contains("timed out") || text.contains("No route to host") {
            return "The machine can't be reached over ssh. (\(text))"
        }
        return text.isEmpty ? "ssh exited with status \(status)." : text
    }

    struct SSHResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func ssh(host: String, command: String, stdin: URL?) async throws -> SSHResult {
        _ = await LoginShellPath.get()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = RemoteEngine.extraSSHArguments + [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=accept-new",
                host, command,
            ]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = LoginShellPath.snapshot()
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            if let stdin {
                guard let handle = try? FileHandle(forReadingFrom: stdin) else {
                    continuation.resume(throwing: Failure(message: "Can't read \(stdin.path)."))
                    return
                }
                process.standardInput = handle
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            let collector = OutputCollector()
            out.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
            err.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut((try? out.fileHandleForReading.readToEnd()) ?? Data())
                collector.appendErr((try? err.fileHandleForReading.readToEnd()) ?? Data())
                continuation.resume(returning: SSHResult(
                    status: proc.terminationStatus,
                    stdout: collector.out,
                    stderr: collector.err
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure(message: "Couldn't run ssh: \(error.localizedDescription)"))
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        func appendOut(_ data: Data) { lock.withLock { outData.append(data) } }
        func appendErr(_ data: Data) { lock.withLock { errData.append(data) } }
        var out: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
        var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }
    }
}

/// Where the Linux `jetlined` binaries come from.
///
/// 1. `JETLINE_DAEMON_DIR`, or a `dist/` folder next to the app (a dev
///    build made with `make app` + `make linux-daemon`), holding
///    `jetlined-linux-<arch>`.
/// 2. A cached download.
/// 3. The GitHub release for this app's version, which carries
///    `jetlined-linux-<arch>.gz` (see .github/workflows/release.yml).
enum DaemonBinaries {
    static let releaseBase = "https://github.com/MartinRybergLaude/jetline/releases/download"

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Jetline/daemon/\(JetlineVersion.current)", isDirectory: true)
    }

    /// A gzipped `jetlined` for `arch`, ready to stream.
    static func gzippedBinary(arch: String, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let name = "jetlined-linux-\(arch)"

        // A local build.
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["JETLINE_DAEMON_DIR"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name))
        if let local = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            await progress("Compressing \(name)…")
            let gz = cacheDirectory.appendingPathComponent("\(name)-local.gz")
            try await gzip(local, to: gz)
            return gz
        }

        // A download, cached per app version.
        let cached = cacheDirectory.appendingPathComponent("\(name).gz")
        if fm.fileExists(atPath: cached.path) { return cached }
        let url = URL(string: "\(releaseBase)/v\(JetlineVersion.current)/\(name).gz")!
        await progress("Downloading jetlined \(JetlineVersion.current) for \(arch)…")
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteInstaller.Failure(message: """
            No jetlined \(JetlineVersion.current) for \(arch) was found (\(url.absoluteString)). \
            Development builds need one next to the app: `make linux-daemon ARCH=\(arch)`.
            """)
        }
        try? fm.removeItem(at: cached)
        try fm.moveItem(at: temp, to: cached)
        return cached
    }

    private static func gzip(_ source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        if let src = try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
           let dst = try? fm.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date,
           dst >= src {
            return
        }
        let result = await Subprocess.run(
            executable: "/bin/sh",
            args: ["-c", "/usr/bin/gzip -c \(RemoteEngine.shellQuote(source.path)) > \(RemoteEngine.shellQuote(destination.path))"]
        )
        guard result.success else {
            throw RemoteInstaller.Failure(message: "Couldn't compress \(source.lastPathComponent): \(result.stderr)")
        }
    }
}
#endif
