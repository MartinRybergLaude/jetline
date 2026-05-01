import Foundation
import AppKit

/// Implementation-agnostic interface for an embedded terminal emulator.
///
/// Two implementations exist:
///   - `SwiftTermEmulator`  ▶ working today, used by default
///   - `GhosttyEmulator`    ▶ planned drop-in once libghostty embedder is wired up
///
/// Switching backends is one-line: see `TerminalBackend.makeView(...)`.
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
}

/// Selects which embedded terminal backend to use.
enum TerminalBackend {
    case swiftTerm
    case ghostty

    /// Default backend. Flip this constant when libghostty integration lands.
    static let `default`: TerminalBackend = .swiftTerm

    @MainActor
    func makeView() -> TerminalEmulatorView {
        switch self {
        case .swiftTerm:
            return SwiftTermEmulator()
        case .ghostty:
            return GhosttyEmulator()
        }
    }
}
