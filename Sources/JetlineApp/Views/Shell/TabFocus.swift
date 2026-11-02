#if os(macOS)
import AppKit

/// Where keyboard focus goes when navigation lands on a tab: a terminal's
/// emulator view, or a chat's composer.
@MainActor
enum TabFocus {
    /// `nil` until the tab's input is showing in `window`.
    static func target(for tab: TabRef?, session: (String) -> PTYSession?, in window: NSWindow) -> NSView? {
        switch tab {
        case .session(let id):
            // Mid-switch the surface can still be parked off-screen.
            guard let view = session(id)?.emulator.nsView, view.window === window else { return nil }
            return view
        case .chat:
            return window.contentView.flatMap { firstDescendant(of: ComposerNSTextView.self, in: $0) }
        case .diff, .launcher, nil:
            return nil
        }
    }

    static func firstDescendant<V: NSView>(of type: V.Type, in root: NSView) -> V? {
        if let match = root as? V { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) { return match }
        }
        return nil
    }
}
#endif
