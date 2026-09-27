import Foundation
import Observation

/// Retained terminal output with absolute byte offsets, so a client that
/// reconnects (or dropped frames while it was slow) can ask for exactly
/// what it missed. Holds the most recent `capacity` bytes. Thread-safe: the
/// PTY appends from its io queue while the server reads on the main actor.
final class TerminalBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    /// Absolute offset of `storage.first`.
    private var start: UInt64 = 0
    private let capacity: Int

    private var sink: (@Sendable (UInt64, Data) -> Void)?

    init(capacity: Int = 4 * 1024 * 1024) {
        self.capacity = capacity
    }

    /// Where new output goes once it's retained — the server's fan-out to
    /// attached clients. Called on the producing (PTY io) queue.
    func setSink(_ sink: (@Sendable (UInt64, Data) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    /// Retain `data` and hand it to the sink.
    func publish(_ data: Data) {
        let offset = append(data)
        let sink = lock.withLock { self.sink }
        sink?(offset, data)
    }

    /// Append and return the offset the chunk starts at.
    func append(_ data: Data) -> UInt64 {
        lock.withLock {
            let offset = start + UInt64(storage.count)
            storage.append(data)
            if storage.count > capacity {
                // Trim to 75% so steady output doesn't re-trim every chunk.
                let drop = storage.count - capacity * 3 / 4
                storage.removeFirst(drop)
                start += UInt64(drop)
            }
            return offset
        }
    }

    var range: (start: UInt64, end: UInt64) {
        lock.withLock { (start, start + UInt64(storage.count)) }
    }

    /// Bytes from `offset` (clamped to what's retained) to the end, and the
    /// offset they actually start at.
    func read(from offset: UInt64?) -> (offset: UInt64, bytes: Data) {
        lock.withLock {
            let from = max(offset ?? start, start)
            let end = start + UInt64(storage.count)
            guard from < end else { return (end, Data()) }
            let skip = Int(from - start)
            return (from, storage.subdata(in: (storage.startIndex + skip)..<storage.endIndex))
        }
    }
}

/// One process on a pseudo-terminal, owned by the engine: an agent or shell
/// tab, or a setup/run script. Its output is retained in `buffer` and fanned
/// out to whichever clients are attached — the process doesn't care whether
/// anyone is watching, so it keeps running with the laptop closed.
///
/// The spawn waits for a real grid size (the first attach's resize, or one
/// given up front) for up to `spawnGrace`, because full-screen TUIs draw for
/// the width they start at.
@MainActor
@Observable
final class EngineTerminal: Identifiable {
    enum Launch: Sendable {
        /// An agent CLI (or the login shell), resolved through `AgentLauncher`.
        case agent(initialPrompt: String?, launchArgs: [String])
        /// A repository script run through the interactive login shell.
        case script(String, env: [String: String])
    }

    let id: String
    let workspaceId: String
    let agent: Workspace.AgentKind
    let cwd: String
    let launch: Launch
    let createdAt = Date()

    private(set) var hasStarted = false
    private(set) var lastError: String?
    private(set) var fellBackToShell = false
    private(set) var exitCode: Int32?

    @ObservationIgnored let buffer = TerminalBuffer()
    @ObservationIgnored private var pty: PTYProcess?
    @ObservationIgnored private var size: TerminalSize?
    @ObservationIgnored private var spawnTask: Task<Void, Never>?
    @ObservationIgnored private var spawnRequested = false
    @ObservationIgnored private var exitHandlers: [(Int32) -> Void] = []
    @ObservationIgnored private let settings: () -> AppSettings

    static let spawnGrace: Duration = .milliseconds(1500)

    init(
        id: String = UUID().uuidString,
        workspaceId: String,
        agent: Workspace.AgentKind,
        cwd: String,
        launch: Launch,
        settings: @escaping () -> AppSettings
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.agent = agent
        self.cwd = cwd
        self.launch = launch
        self.settings = settings
    }

    var info: TerminalInfo {
        TerminalInfo(
            id: id,
            workspaceId: workspaceId,
            agent: agent,
            cwd: cwd,
            hasStarted: hasStarted,
            lastError: lastError,
            fellBackToShell: fellBackToShell,
            exitCode: exitCode
        )
    }

    var isRunning: Bool { hasStarted && exitCode == nil }

    /// Register a handler for the process's exit. Fires immediately if it
    /// already exited.
    func onExit(_ handler: @escaping (Int32) -> Void) {
        if let exitCode {
            handler(exitCode)
        } else {
            exitHandlers.append(handler)
        }
    }

    /// Ask for the process to start. With a size it spawns right away;
    /// otherwise it waits (briefly) for one.
    func start(size: TerminalSize?) {
        guard !spawnRequested else {
            if let size { resize(size) }
            return
        }
        spawnRequested = true
        if let size {
            self.size = size
            spawnNow()
            return
        }
        spawnTask = Task { [weak self] in
            try? await Task.sleep(for: Self.spawnGrace)
            guard !Task.isCancelled else { return }
            self?.spawnNow()
        }
    }

    func resize(_ size: TerminalSize) {
        self.size = size
        if let pty {
            pty.resize(cols: size.cols, rows: size.rows, widthPx: size.widthPx, heightPx: size.heightPx)
        } else if spawnRequested, spawnTask != nil {
            spawnTask?.cancel()
            spawnTask = nil
            spawnNow()
        }
    }

    func write(_ data: Data) {
        pty?.write(data)
    }

    func interrupt() {
        pty?.interrupt()
    }

    /// Stop the process. `completion` fires once every process it started is
    /// gone (see `PTYProcess.terminate`).
    func terminate(completion: (@Sendable () -> Void)? = nil) {
        spawnTask?.cancel()
        spawnTask = nil
        guard let pty else {
            if spawnRequested, !hasStarted, exitCode == nil {
                // Never spawned: settle it so waiters don't hang.
                spawnRequested = true
                markExited(0)
            }
            completion?()
            return
        }
        pty.terminate(completion: completion)
    }

    /// Output as plain text, for "copy output".
    func plainText() -> String {
        let raw = String(decoding: buffer.read(from: nil).bytes, as: UTF8.self)
        return TerminalText.stripControlSequences(raw)
    }

    private func spawnNow() {
        spawnTask = nil
        guard !hasStarted, exitCode == nil else { return }
        hasStarted = true
        let size = self.size ?? TerminalSize(cols: 80, rows: 24)
        Task { [weak self] in
            guard let self else { return }
            let executable: String
            let args: [String]
            var env: [String: String]
            switch self.launch {
            case let .agent(initialPrompt, launchArgs):
                do {
                    let spec = try await AgentLauncher.spec(
                        for: self.agent,
                        settings: self.settings(),
                        initialPrompt: initialPrompt,
                        launchArgs: launchArgs
                    )
                    self.fellBackToShell = spec.fellBackToShell
                    executable = spec.executable
                    args = spec.args
                    env = spec.env
                } catch {
                    self.lastError = error.localizedDescription
                    self.markExited(127)
                    return
                }
            case let .script(script, scriptEnv):
                executable = ShellScriptLauncher.shell
                args = ShellScriptLauncher.args(for: script)
                env = scriptEnv
            }
            _ = await LoginShellPath.get()
            var environment = Subprocess.inheritedEnvironment(overrides: env)
            environment["TERM"] = environment["TERM"] ?? "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            self.spawn(executable: executable, args: args, env: environment, size: size)
        }
    }

    private func spawn(executable: String, args: [String], env: [String: String], size: TerminalSize) {
        let buffer = self.buffer
        let pty = PTYProcess(
            executable: executable,
            args: args,
            cwd: cwd,
            env: env,
            initialCols: size.cols,
            initialRows: size.rows,
            output: { data in
                buffer.publish(data)
            },
            exit: { [weak self] code in
                Task { @MainActor in
                    self?.pty = nil
                    self?.markExited(code)
                }
            }
        )
        do {
            try pty.start()
            self.pty = pty
            if let current = self.size, current != size {
                pty.resize(cols: current.cols, rows: current.rows, widthPx: current.widthPx, heightPx: current.heightPx)
            }
        } catch {
            let message = "jetline: failed to spawn \(executable): \(error)\r\n"
            buffer.publish(Data(message.utf8))
            lastError = "\(error)"
            markExited(127)
        }
    }

    private func markExited(_ code: Int32) {
        guard exitCode == nil else { return }
        exitCode = code
        let handlers = exitHandlers
        exitHandlers.removeAll()
        for handler in handlers { handler(code) }
    }
}

/// Plain-text rendering of terminal output.
enum TerminalText {
    /// Strip CSI / OSC / single-char ESC sequences and collapse `\r\n` to
    /// `\n`. Keeps printable text + `\n` + `\t` so copy/paste from a long
    /// run is readable. Standalone `\r` (carriage return without newline,
    /// used by progress bars to redraw a line) becomes a newline so the
    /// clipboard shows the redraws as separate lines instead of overlap.
    static func stripControlSequences(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            switch c {
            case "\u{1B}":
                let next = s.index(after: i)
                guard next < s.endIndex else { return out }
                let n = s[next]
                if n == "[" {
                    // CSI: ESC [ params final-byte (0x40-0x7E)
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        let cc = s[j]
                        j = s.index(after: j)
                        if let ascii = cc.asciiValue, ascii >= 0x40, ascii <= 0x7E { break }
                    }
                    i = j
                } else if n == "]" {
                    // OSC: ESC ] ... BEL  or  ESC ] ... ESC \
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        if s[j] == "\u{07}" { j = s.index(after: j); break }
                        if s[j] == "\u{1B}" {
                            let after = s.index(after: j)
                            if after < s.endIndex, s[after] == "\\" {
                                j = s.index(after: after); break
                            }
                        }
                        j = s.index(after: j)
                    }
                    i = j
                } else {
                    // Two-byte ESC sequences (e.g. character-set selection).
                    i = s.index(after: next)
                }
            case "\r":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "\n" {
                    out.append("\n"); i = s.index(after: next)
                } else {
                    out.append("\n"); i = next
                }
            case "\u{07}", "\u{08}":
                // BEL and BS — drop, they don't survive a copy meaningfully.
                i = s.index(after: i)
            default:
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}
