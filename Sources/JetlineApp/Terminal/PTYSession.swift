import Foundation
import AppKit

/// One running agent session. Holds the terminal view + emulator backend.
/// Sessions are kept alive while their workspace is open; switching tabs
/// only swaps which session's view is visible — none of them are killed.
@MainActor
final class PTYSession: ObservableObject, Identifiable {
    let id: String
    let workspaceId: String
    let agent: Workspace.AgentKind
    let cwd: String
    let isResume: Bool
    /// Initial prompt to send to the agent on first start, as a positional
    /// argument. Used by the inspector's git action bar; nil for plain new
    /// tabs. Ignored on resume.
    let initialPrompt: String?
    let emulator: TerminalEmulatorView

    @Published private(set) var hasStarted: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var fellBackToShell: Bool = false

    init(
        id: String = UUID().uuidString,
        workspaceId: String,
        agent: Workspace.AgentKind,
        cwd: String,
        isResume: Bool = false,
        initialPrompt: String? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.agent = agent
        self.cwd = cwd
        self.isResume = isResume
        self.initialPrompt = initialPrompt
        self.emulator = TerminalEmulatorFactory.make()
    }

    /// Resolve the binary path and start the agent process. Idempotent —
    /// calling twice is a no-op. The actual `forkpty` is deferred by the
    /// emulator until its NSView is in a window with non-zero bounds.
    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            let settings = try SettingsStore.load()
            let spec = try await AgentLauncher.spec(
                for: agent,
                settings: settings,
                sessionId: id,
                isResume: isResume,
                initialPrompt: initialPrompt
            )
            fellBackToShell = spec.fellBackToShell
            emulator.spawn(executable: spec.executable, args: spec.args, cwd: cwd, env: spec.env)
            emulator.updateFont(family: settings.terminalFontFamily, size: settings.terminalFontSize)
        } catch {
            lastError = error.localizedDescription
            hasStarted = false
        }
    }

    func interrupt() { emulator.sendInterrupt() }

    func terminate() { emulator.terminate() }
}
