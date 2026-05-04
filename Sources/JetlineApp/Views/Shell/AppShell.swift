import SwiftUI
import AppKit

/// Top-level layout: sidebar on the left, terminal in the middle,
/// inspector on the right (toggleable).
struct AppShell: View {
    @EnvironmentObject private var state: AppState

    init() {
        MenuFirstShortcutMonitor.install()
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            MainArea()
                .inspector(isPresented: inspectorBinding) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 320, max: 480)
                }
        }
        .background(WindowTabbingDisabler())
        .task { await state.load() }
    }

    /// Inspector hides when nothing is selected (mirrors the previous logic),
    /// otherwise tracks the user-toggled visibility flag.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { state.inspectorVisible && state.selectedWorkspaceId != nil },
            set: { state.inspectorVisible = $0 }
        )
    }
}

/// Disables NSWindow tabbing for the hosting window — removes the
/// View → Show Tab Bar / Merge All Windows / Move Tab to New Window items.
/// Applied once per window via `viewDidMoveToWindow`; SwiftUI reuses the
/// same NSView across updates, so we don't need to re-apply on every
/// `updateNSView`.
private struct WindowTabbingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> TabbingDisablerView { TabbingDisablerView() }
    func updateNSView(_ view: TabbingDisablerView, context: Context) {}
}

private final class TabbingDisablerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.tabbingMode = .disallowed
    }
}

/// AppKit's default `NSWindow.performKeyEquivalent` walks the content view
/// hierarchy *first* and only falls back to the main menu if no view claims
/// the event. Ghostty's `AppTerminalView` answers `true` for any key that
/// resolves to one of its internal bindings — which makes ⌘T / ⌘W /
/// ⌃Tab / ⌘1-9 work only intermittently (when the terminal isn't first
/// responder). Inverting the priority via a local event monitor: hand the
/// main menu first crack on every modifier-keyed keyDown, fall through if
/// the menu doesn't claim it. Installed once, app-wide.
@MainActor
private enum MenuFirstShortcutMonitor {
    private static var token: Any?

    static func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command) || mods.contains(.control) else { return event }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return nil
            }
            return event
        }
    }
}

private struct MainArea: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let id = state.selectedWorkspaceId, let ws = state.workspaceById(id) {
            TerminalArea(workspace: ws)
        } else {
            WelcomeView()
        }
    }
}
