import AppKit

/// Hidden offscreen NSWindow that holds run / setup script terminal views
/// while they're not visible in the inspector. libghostty's
/// `InMemoryTerminalSession` silently drops bytes whenever its surface is
/// nil, and the surface only gets built once the hosting `AppTerminalView`
/// is attached to a window. Without this incubator, a script running in
/// workspace A while the user is on workspace B (or has the inspector on
/// the Changes tab) would see all of its output dropped on the floor.
///
/// Lifecycle:
/// 1. `RunController` / `SetupController` calls `park(_:)` right after
///    spawning the script — the emulator joins the incubator window, its
///    surface is built, and PTY output flows into ghostty's scrollback.
/// 2. When the inspector's run panel mounts, it calls `adopt(_:into:)` to
///    move the emulator into the inspector container. The surface persists
///    across the move (libghostty preserves it on detach/reattach).
/// 3. When the panel dismounts, the panel re-parks the emulator. Surface
///    stays alive; bytes keep accumulating.
@MainActor
enum TerminalIncubator {
    private static let window: NSWindow = makeWindow()

    /// Move `view` into the incubator's contentView. No-op if it's already
    /// parked there.
    static func park(_ view: NSView) {
        guard let parent = window.contentView, view.superview !== parent else { return }
        view.removeFromSuperview()
        parent.addSubview(view)
    }

    /// Move `view` out of wherever it is and into `parent`. The caller is
    /// responsible for installing constraints; this just handles the
    /// reparenting. No-op when `view` is already inside `parent`.
    static func adopt(_ view: NSView, into parent: NSView) {
        guard view.superview !== parent else { return }
        view.removeFromSuperview()
        parent.addSubview(view)
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = NSView()
        return window
    }
}
