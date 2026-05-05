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
    /// Initial prompt to send to the agent on first start, as a positional
    /// argument. Used by the inspector's git action bar; nil for plain new
    /// tabs.
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
        initialPrompt: String? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.agent = agent
        self.cwd = cwd
        self.initialPrompt = initialPrompt
        self.emulator = TerminalEmulatorFactory.make()
        // Keep the AppTerminalView in a window from the moment it exists.
        // libghostty's InMemoryTerminalSession drops every byte until the
        // surface is built, and the surface only exists once the view has
        // a window. Without this, two races produce empty-canvas tabs:
        //   1. Fresh tab: SwiftUI hasn't yet mounted the host view when
        //      the spawn Task fires, so the agent's startup banner is
        //      written into a nil surface and lost.
        //   2. Tab switch: SwiftUI dismantles the host on `.id` change,
        //      orphaning the term (no window → surface destroyed). When
        //      the user returns, addSubview rebuilds an empty surface.
        // Parking offscreen by default keeps the surface alive across
        // both transitions; SwiftUI's `addSubview` in makeNSView pulls
        // the view back out into the active container, and
        // `dismantleNSView` parks it back when the tab is hidden.
        TerminalIncubator.park(emulator.nsView)
        emulator.setActive(false)
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
