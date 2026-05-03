import Foundation
import AppKit

/// Implementation-agnostic interface for an embedded terminal emulator.
/// Backed by `GhosttyEmulator` — the SwiftTerm backend was removed when
/// the migration to libghostty landed (its DECSET 2026 bookkeeping
/// produced overdraw under Claude Code's flicker-free TUI).
@MainActor
protocol TerminalEmulatorView: AnyObject {
    /// The underlying NSView to host inside SwiftUI.
    var nsView: NSView { get }

    /// Spawn a process inside this terminal. Replaces any existing one.
    func spawn(executable: String, args: [String], cwd: String, env: [String: String])

    /// Send `^C` (or equivalent) to the process.
    func sendInterrupt()

    /// Write raw bytes to the PTY input.
    func write(_ string: String)

    /// Adopt new font/size at runtime.
    func updateFont(family: String, size: CGFloat)

    /// Stop the process and tear down the PTY.
    func terminate()

    /// Toggle Metal rendering when the tab is hidden / shown. Inactive
    /// surfaces should pause display-link work to keep the GPU idle.
    func setActive(_ active: Bool)

    /// Register a handler that fires once when the underlying process
    /// exits (clean exit, signal, or fork failure). The host uses this to
    /// reconcile DB state — e.g. mark the persisted session row ended so
    /// a broken `--resume` doesn't keep cycling. Set before `spawn`.
    func setExitHandler(_ handler: @escaping (Int32) -> Void)
}

extension TerminalEmulatorView {
    func setActive(_ active: Bool) {}
}

@MainActor
enum TerminalEmulatorFactory {
    static func make() -> TerminalEmulatorView {
        GhosttyEmulator()
    }
}
