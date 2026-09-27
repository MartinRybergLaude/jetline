import Foundation
import Observation

/// A workspace's setup or run script, engine side. The script runs on an
/// `EngineTerminal` so any client can attach and watch it; this object adds
/// the lifecycle the toolbar and run panel show.
///
/// Run: `idle → (queued →) starting → running → idle` with the last exit
/// status kept. Setup: `running → finished`.
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

    /// Start once `clearance` resolves — an exclusive run waiting until the
    /// peers it displaces are really gone (a peer that ignores SIGHUP
    /// reports its exit immediately but can hold the port this run is about
    /// to bind until the force-kill lands). Goes to `.queued` up front so a
    /// second click stops it rather than starting a second copy.
    func start(
        script: String,
        cwd: String,
        env: [String: String],
        after clearance: @escaping @MainActor () async -> Void
    ) {
        guard kind == .run, phase == .idle, let trimmed = script.nonBlank else { return }
        phase = .queued
        // Retire the previous run's terminal now, so the panel doesn't show
        // a dead transcript for as long as the queue takes.
        terminal = nil
        exitStatus = nil
        pendingStart = Task { @MainActor [weak self] in
            await clearance()
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

    /// Stop the run. SIGHUP to the script's process groups, escalating to
    /// SIGKILL for anything still alive a moment later.
    func stop() {
        if cancelPendingStart() { return }
        terminal?.terminate()
    }

    /// Stop, and wait until every process the run started is gone — not
    /// merely until the shell reported its exit. What the caller is usually
    /// waiting for is the port, and that outlives the exit when the job
    /// ignores SIGHUP.
    func stopAndWait() async {
        if cancelPendingStart() { return }
        guard let terminal else { return }
        await withCheckedContinuation { continuation in
            terminal.terminate { continuation.resume() }
        }
    }

    /// Tear down: the workspace is going away.
    func discard() {
        cancelPendingStart()
        warmup?.cancel()
        terminal?.terminate()
        terminal = nil
    }

    @discardableResult
    private func cancelPendingStart() -> Bool {
        guard let pending = pendingStart else { return false }
        pending.cancel()
        pendingStart = nil
        phase = .idle
        return true
    }

    private func handleExit(code: Int32) {
        warmup?.cancel()
        warmup = nil
        switch kind {
        case .run:
            guard phase != .idle else { return }
            phase = .idle
        case .setup:
            guard phase == .running else { return }
            phase = .finished
        }
        exitStatus = code
    }
}
