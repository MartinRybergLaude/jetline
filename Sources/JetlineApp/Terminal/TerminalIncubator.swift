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
/// 1. `RunController` / `SetupController` calls `park(_:)` before
///    spawning the script — the emulator joins the incubator window, its
///    surface is built, and PTY output flows into ghostty's scrollback.
/// 2. When the inspector's run panel mounts, it calls `adopt(_:into:)` to
///    move the emulator into the inspector container. The surface persists
///    across the move (libghostty preserves it on detach/reattach).
/// 3. When the panel dismounts, the panel re-parks the emulator. Surface
///    stays alive; bytes keep accumulating.
@MainActor
enum TerminalIncubator {
    private static let parkedSize = NSSize(width: 960, height: 600)
    private static let window: NSWindow = makeWindow()

    /// Views must be at least this large to keep their own size when
    /// parked; anything smaller (fresh views are zero-sized) gets
    /// `parkedSize` so the surface has a real grid to build against.
    private static let minPreservedSize = NSSize(width: 64, height: 64)

    /// Move `view` into the incubator's contentView, keeping it at a real
    /// terminal size. A view that was live keeps its current frame: forcing
    /// `parkedSize` here would round-trip the PTY through a foreign grid on
    /// every tab switch (SIGWINCH → TUI redraw at the parked size, and again
    /// on return), re-wrapping inline-drawn TUIs like Claude Code. Parking
    /// size-neutral means hide/show fires no resize at all unless the
    /// container genuinely changed size while the view was hidden. Parked
    /// views may exceed the incubator window's bounds; the window is
    /// invisible and the surface doesn't care about clipping.
    static func park(_ view: NSView) {
        guard let parent = window.contentView else { return }

        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        let hasLiveSize = view.frame.width >= minPreservedSize.width
            && view.frame.height >= minPreservedSize.height
        view.frame = NSRect(
            origin: .zero,
            size: hasLiveSize ? view.frame.size : parkedSize
        )

        guard view.superview !== parent else {
            view.layoutSubtreeIfNeeded()
            return
        }

        view.removeFromSuperview()
        parent.addSubview(view)
        view.layoutSubtreeIfNeeded()
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
            contentRect: NSRect(origin: .zero, size: parkedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: parkedSize))
        return window
    }
}
