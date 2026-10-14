import Foundation
import Observation

/// A workspace's setup or run script, engine side. The script runs on an
/// `EngineTerminal` so any client can attach and watch it; this object adds
/// the lifecycle the toolbar and run panel show.
///
/// Run: `idle → (queued →) (stopping →) starting → running → stopping →
/// idle` with the last exit status kept. Setup: `running → finished`.
///
/// Stopping a run also cleans up after it: processes that detached from its
/// process groups (`RunProcessTracker`), then the repository's stop script
/// for what lives outside the machine's process table (containers). A run
/// that ended on its own gets the same cleanup before the next one starts,
/// as does the first run after launch, since an earlier engine may have
/// left something behind.
@MainActor
@Observable
final class ScriptRun {
    enum Kind { case setup, run }

    let kind: Kind
    let workspaceId: String
    private(set) var phase: ScriptRunInfo.Phase
    private(set) var exitStatus: Int32?
    private(set) var terminal: EngineTerminal?

    @ObservationIgnored private var pendingStart: Task<Void, Never>?
    @ObservationIgnored private var warmup: Task<Void, Never>?
    @ObservationIgnored private let settings: () -> AppSettings
    @ObservationIgnored private var cleanup: Cleanup?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    /// The last run may have left something behind: it hasn't been
    /// stopped through `stop` since it started (or since launch).
    @ObservationIgnored private var needsCleanup = true

    /// What stopping a run does after its process groups are gone.
    struct Cleanup: Sendable {
        var tracker: RunProcessTracker?
        var stopScript: String?
        var cwd: String
        var env: [String: String]

        /// `terminal` is the stopped run's, for the stop script's output.
        @MainActor
        func perform(terminal: EngineTerminal?) async {
            await tracker?.terminateAll()
            guard let stopScript else { return }
            terminal?.note("Running the stop script…")
            let result = await ScriptRunner.run(stopScript, cwd: cwd, env: env, timeout: 120)
            guard let terminal, let result else { return }
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { terminal.note(output) }
            terminal.note(result.success ? "Stop script done." : "Stop script failed (exit \(result.status)).")
        }
    }

    /// How long a stopped run gets to clean up after itself (an exit trap
    /// taking containers down) before what's left is killed.
    static let stopGrace: DispatchTimeInterval = .seconds(30)

    /// ⌃C the run, wait for it to wind down, then the cleanup.
    @MainActor
    private static func stopAndClean(_ terminal: EngineTerminal?, _ cleanup: Cleanup?) async {
        await cleanup?.tracker?.refresh()
        if let terminal {
            await withCheckedContinuation { continuation in
                terminal.stopGracefully(grace: stopGrace) { continuation.resume() }
            }
        }
        await cleanup?.perform(terminal: terminal)
    }

    /// `.starting` flips to `.running` once the process has stayed alive this
    /// long — proxy for "spawn actually took effect".
    private static let startupGrace: Duration = .seconds(1)

    init(kind: Kind, workspaceId: String, settings: @escaping () -> AppSettings) {
        self.kind = kind
        self.workspaceId = workspaceId
        self.settings = settings
        self.phase = kind == .setup ? .running : .idle
    }

    var info: ScriptRunInfo {
        ScriptRunInfo(phase: phase, exitStatus: exitStatus, terminalId: terminal?.id)
    }

    /// The processes the current (or last) run started.
    var tracker: RunProcessTracker? { cleanup?.tracker }

    var isRunning: Bool {
        switch kind {
        case .run: return phase != .idle
        case .setup: return phase == .running
        }
    }

    func start(script: String, cwd: String, env: [String: String]) {
        guard let trimmed = script.nonBlank else {
            if kind == .setup { phase = .finished; exitStatus = 0 }
            return
        }
        if kind == .run { guard phase == .idle else { return } }
        spawn(script: trimmed, cwd: cwd, env: env)
    }

    /// Start a run, first cleaning up after the last one when it wasn't
    /// stopped here, and waiting for `clearance` when given — an exclusive
    /// run waiting until the peers it displaces are really gone (a peer
    /// that ignores SIGHUP reports its exit immediately but can hold the
    /// port this run is about to bind until the force-kill lands). Leaves
    /// `.idle` up front so a second click stops it rather than starting a
    /// second copy.
    func startRun(
        script: String,
        stopScript: String?,
        cwd: String,
        env: [String: String],
        after clearance: (@MainActor () async -> Void)? = nil
    ) {
        guard kind == .run, phase == .idle, let trimmed = script.nonBlank else { return }
        // The last run's processes, with this run's stop script: the
        // current settings are the best guess at what cleans up.
        let cleanup = Cleanup(tracker: self.cleanup?.tracker, stopScript: stopScript, cwd: cwd, env: env)
        self.cleanup = cleanup
        let mustClean = needsCleanup
        guard clearance != nil || mustClean else {
            spawn(script: trimmed, cwd: cwd, env: env)
            return
        }
        phase = clearance != nil ? .queued : .stopping
        // Retire the previous run's terminal now, so the panel doesn't show
        // a dead transcript for as long as the queue takes.
        terminal = nil
        exitStatus = nil
        pendingStart = Task { @MainActor [weak self] in
            await clearance?()
            guard !Task.isCancelled else { return }
            if mustClean {
                self?.phase = .stopping
                await cleanup.perform(terminal: nil)
                self?.needsCleanup = false
                // Cancelled mid-cleanup: `.idle` only now that it's done.
                if Task.isCancelled { self?.phase = .idle }
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingStart = nil
            self.spawn(script: trimmed, cwd: cwd, env: env)
        }
    }

    private func spawn(script: String, cwd: String, env: [String: String]) {
        let term = EngineTerminal(
            workspaceId: workspaceId,
            agent: .shell,
            cwd: cwd,
            launch: .script(script, env: env),
            settings: settings
        )
        terminal = term
        exitStatus = nil
        phase = kind == .setup ? .running : .starting
        if kind == .run { needsCleanup = true }
        if kind == .run {
            let tracker = RunProcessTracker()
            cleanup?.tracker = tracker
            term.onSpawn = { tracker.track(root: $0) }
        }
        term.onExit { [weak self, weak term] code in
            guard let self, let term, self.terminal === term else { return }
            self.handleExit(code: code)
        }
        term.start(size: nil)
        guard kind == .run else { return }
        warmup = Task { [weak self] in
            try? await Task.sleep(for: Self.startupGrace)
            guard let self, !Task.isCancelled, self.phase == .starting else { return }
            self.phase = .running
        }
    }

    /// Stop the run: SIGINT, like ⌃C, so its own cleanup runs; SIGKILL for
    /// whatever is still alive after `stopGrace`; then the cleanup. Stopping
    /// a run that is already stopping kills it outright.
    func stop() {
        if cancelPendingStart() { return }
        if stopping != nil {
            terminal?.terminate()
            return
        }
        beginStopping()
    }

    /// Stop, and wait until every process the run started is gone — not
    /// merely until the shell reported its exit — and the cleanup is done.
    /// What the caller is usually waiting for is the port, and that
    /// outlives the exit when the job ignores SIGHUP or detached.
    func stopAndWait() async {
        if cancelPendingStart() { return }
        await beginStopping()?.value
    }

    @discardableResult
    private func beginStopping() -> Task<Void, Never>? {
        if let stopping { return stopping }
        guard kind == .run, let terminal, phase != .idle else {
            terminal?.terminate()
            return nil
        }
        warmup?.cancel()
        phase = .stopping
        let cleanup = self.cleanup
        if terminal.isRunning { terminal.note("Stopping… (press Stop again to kill it now)") }
        let task = Task { @MainActor [weak self] in
            await Self.stopAndClean(terminal, cleanup)
            guard let self else { return }
            self.stopping = nil
            self.needsCleanup = false
            self.phase = .idle
        }
        stopping = task
        return task
    }

    /// Tear down: the workspace is going away. The cleanup still runs, in
    /// the background.
    func discard() {
        cancelPendingStart()
        warmup?.cancel()
        if kind == .run, stopping == nil, needsCleanup, let cleanup {
            let terminal = self.terminal
            Task { await Self.stopAndClean(terminal, cleanup) }
        } else {
            terminal?.terminate()
        }
        terminal = nil
    }

    @discardableResult
    private func cancelPendingStart() -> Bool {
        guard let pending = pendingStart else { return false }
        pending.cancel()
        pendingStart = nil
        if phase != .stopping { phase = .idle }
        return true
    }

    private func handleExit(code: Int32) {
        warmup?.cancel()
        warmup = nil
        switch kind {
        case .run:
            // Stopping: `.idle` once the cleanup is done.
            guard phase != .idle else { return }
            if phase != .stopping { phase = .idle }
        case .setup:
            guard phase == .running else { return }
            phase = .finished
        }
        exitStatus = code
    }
}
