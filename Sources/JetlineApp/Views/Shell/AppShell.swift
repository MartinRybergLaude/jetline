import SwiftUI
import AppKit

/// Top-level layout: sidebar on the left, terminal in the middle,
/// inspector on the right (toggleable).
struct AppShell: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    init() {
        MenuFirstShortcutMonitor.install()
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // Stands in for the titlebar separator AppKit won't draw
                // reliably — see `WindowChromeView.silenceTitlebarSeparators`.
                Hairline()
                MainArea()
            }
            .inspector(isPresented: inspectorBinding) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 320, max: 480)
            }
        }
        .background(WindowChromeSetup())
        .sheet(item: $state.repoPendingWorkspaceCreation) { repo in
            WorkspaceCreationSheet(repository: repo)
        }
        .sheet(item: $state.repoPendingSettings) { repo in
            RepositorySettingsSheet(repository: repo)
        }
        .task {
            await state.load()
            // Open the welcome flow on the first launch after install (or
            // after the user clears the flag via the Debug menu). The
            // OnboardingView itself flips the flag the first time it
            // appears so a subsequent relaunch stays quiet.
            if !state.settings.hasCompletedOnboarding {
                openWindow(id: "onboarding")
            }
        }
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

/// Window chrome SwiftUI doesn't expose: tabbing and the titlebar separator.
private struct WindowChromeSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }

    // Split items get rebuilt as columns come and go (showing the inspector
    // makes a fresh one), and each starts out `.automatic` again — so re-apply
    // on every update rather than once at mount. The new item isn't installed
    // until the update pass finishes, hence the trailing hop.
    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.silenceTitlebarSeparators()
        DispatchQueue.main.async { view.silenceTitlebarSeparators() }
    }
}

private final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Removes View → Show Tab Bar / Merge All Windows / Move Tab to New Window.
        window.tabbingMode = .disallowed
        silenceTitlebarSeparators()
        // The split view isn't built yet on the first pass through here.
        DispatchQueue.main.async { [weak self] in self?.silenceTitlebarSeparators() }
    }

    /// Silences AppKit's own hairline under the toolbar, which we draw in
    /// SwiftUI instead (`Hairline` at the top of the detail and inspector
    /// columns). `.automatic` decides per split item and on a freshly
    /// launched window it lands on "no line" for the detail column — the
    /// hairline only turns up once toggling the inspector rebuilds a split
    /// item. Nothing short of that changes its mind: not `.line` on the item,
    /// not `NSWindow.titlebarSeparatorStyle` (an item's own style wins), not a
    /// forced layout, toolbar reassignment or resize. So take AppKit out of
    /// the decision entirely. The sidebar keeps `.automatic`, where it works —
    /// its list is a scroll view, the case the automatic behaviour is built
    /// around.
    func silenceTitlebarSeparators() {
        guard let root = window?.contentView else { return }
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController {
                for item in controller.splitViewItems where item.behavior != .sidebar {
                    item.titlebarSeparatorStyle = .none
                }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
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
            TerminalArea(workspace: ws, workspaceState: state.workspaceState(for: id))
        } else {
            WelcomeView()
        }
    }
}
