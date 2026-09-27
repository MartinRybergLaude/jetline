#if os(macOS)
import Foundation
import AppKit

/// One terminal tab: a Ghostty surface attached to an engine terminal (an
/// agent TUI or a shell). The process lives in the engine — this app's own,
/// or a remote `jetlined` — so switching tabs, and on a remote engine even
/// quitting the app, never kills it.
@MainActor
final class PTYSession: ObservableObject, Identifiable {
    let id: String
    let workspaceId: String
    let agent: Workspace.AgentKind
    let cwd: String
    let emulator: TerminalEmulatorView
    let channel: TerminalChannel

    @Published private(set) var hasStarted: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var fellBackToShell: Bool = false
    @Published private(set) var exitCode: Int32?

    init(info: TerminalInfo, connection: EngineConnection) {
        self.id = info.id
        self.workspaceId = info.workspaceId
        self.agent = info.agent
        self.cwd = info.cwd
        self.emulator = TerminalEmulatorFactory.make()
        self.channel = TerminalChannel(terminalId: info.id, connection: connection)
        apply(info)
        // Keep the AppTerminalView in a window from the moment it exists.
        // libghostty's InMemoryTerminalSession drops every byte until the
        // surface is built, and the surface only exists once the view has
        // a window. Parking offscreen keeps the surface alive across tab
        // switches (SwiftUI dismantles the host on `.id` change) and lets
        // it report its grid before the first byte arrives; SwiftUI's
        // `addSubview` in makeNSView pulls the view into the active
        // container, and `dismantleNSView` parks it back when hidden.
        TerminalIncubator.park(emulator.nsView)
        emulator.setActive(false)
    }

    func apply(_ info: TerminalInfo) {
        if hasStarted != info.hasStarted { hasStarted = info.hasStarted }
        if lastError != info.lastError { lastError = info.lastError }
        if fellBackToShell != info.fellBackToShell { fellBackToShell = info.fellBackToShell }
        if exitCode != info.exitCode { exitCode = info.exitCode }
    }

    /// Connect the surface to the engine terminal. Idempotent; call again
    /// after a reconnect to resume from where output left off.
    func startIfNeeded() async {
        attach()
    }

    func attach() {
        if !attached {
            attached = true
            emulator.attach(channel)
            let settings = AppState.shared.settings
            emulator.updateFont(family: MonoFont.terminalFamily(settings.monospaceFontFamily), size: settings.terminalFontSize)
        } else {
            channel.attach()
        }
    }

    private var attached = false

    func interrupt() { emulator.sendInterrupt() }

    /// End the process and the tab.
    func terminate() { emulator.terminate() }

    /// Stop showing it here; the process keeps running in the engine.
    func detach() { emulator.detach() }
}
#endif
