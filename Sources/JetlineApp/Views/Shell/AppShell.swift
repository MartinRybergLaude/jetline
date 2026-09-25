import SwiftUI
import AppKit

/// One tab window's layout, the way Xcode builds its own: an AppKit split
/// view with a full-height sidebar and inspector either side of the tab's
/// content, each column hosting its SwiftUI view. The native tab bar sits
/// over the content column only — the sidebar and inspector belong to the
/// workspace, not to the tab.
///
/// Not SwiftUI's `NavigationSplitView` + `.inspector`: revealing that
/// inspector in a window without room for it grows the window and pins the
/// content column, and on macOS 27 AppKit's titlebar layout then loops until
/// it throws (reproducible in a bare `WindowGroup`). Here the inspector takes
/// its room from the content column, as in Xcode.
@MainActor
final class TabSplitController: NSSplitViewController {
    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    private weak var coordinator: MainWindowCoordinator?
    private var collapseObservations: [NSKeyValueObservation] = []

    init(
        slot: TabSlot,
        state: AppState,
        coordinator: MainWindowCoordinator,
        environment: @escaping (AnyView) -> AnyView
    ) {
        self.coordinator = coordinator

        let sidebar = NSHostingController(rootView: environment(AnyView(SidebarView())))
        sidebar.sizingOptions = []
        sidebar.sceneBridgingOptions = []
        sidebar.view.frame.size.width = 260
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = MainWindowCoordinator.sidebarMinimum
        sidebarItem.maximumThickness = 320

        // Nothing bridged: the toolbar and the window title are AppKit's
        // (`TabToolbar`).
        let content = NSHostingController(rootView: environment(AnyView(
            TabContentRoot(slot: slot, coordinator: coordinator)
        )))
        content.sizingOptions = []
        content.sceneBridgingOptions = []
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = MainWindowCoordinator.contentMinimum

        let inspector = NSHostingController(rootView: environment(AnyView(
            InspectorView()
                // Wider than it looks like it needs: every panel here is
                // monospaced content that truncates badly — diff lines,
                // branch refs, check names — so 320 spent most of its time
                // showing ellipses. 240 stays the floor for people who want
                // the terminal back.
                .frame(minWidth: MainWindowCoordinator.inspectorMinimum, maxWidth: .infinity)
        )))
        inspector.sizingOptions = []
        inspector.sceneBridgingOptions = []
        inspector.view.frame.size.width = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = MainWindowCoordinator.inspectorMinimum
        inspectorItem.maximumThickness = 600
        inspectorItem.addTopAlignedAccessoryViewController(InspectorTabsAccessory(state: state))

        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        // Collapses the coordinator didn't ask for — a divider dragged shut,
        // a pane auto-collapsed by a window resize — are shared with the
        // other tab windows.
        collapseObservations = [sidebarItem, inspectorItem].map { item in
            item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.coordinator?.paneCollapseChanged(in: self)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // The toolbar's sidebar / inspector buttons and the View menu land here.
    // Route them through the coordinator so every tab window follows.
    override func toggleSidebar(_ sender: Any?) {
        coordinator?.toggleSidebar()
    }

    override func toggleInspector(_ sender: Any?) {
        coordinator?.toggleInspector()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleInspector(_:)) {
            return coordinator?.canShowInspector ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// The content column of a tab window.
private struct TabContentRoot: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    let slot: TabSlot
    let coordinator: MainWindowCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Stands in for the titlebar separator AppKit won't draw
            // reliably — see `WindowChromeView.silenceTitlebarSeparators`.
            Hairline()
            SlotContent(slot: slot)
        }
        // Report a fixed floor instead of whatever the tab's content wants
        // (a chat's composer row alone is wider than this), so the columns
        // always fit the window.
        .frame(minWidth: MainWindowCoordinator.contentMinimum, maxWidth: .infinity)
        .background(WindowChromeSetup())
        // App-level sheets belong to the visible tab only — every tab window
        // observes the same state.
        .sheet(item: selectedOnly($state.repoPendingWorkspaceCreation)) { repo in
            WorkspaceCreationSheet(repository: repo)
        }
        .sheet(item: selectedOnly($state.repoPendingSettings)) { repo in
            RepositorySettingsSheet(repository: repo)
        }
        .onAppear {
            if coordinator.openWindow == nil { coordinator.openWindow = openWindow }
        }
    }

    private func selectedOnly<T>(_ binding: Binding<T?>) -> Binding<T?> {
        Binding(
            get: { slot.isSelected ? binding.wrappedValue : nil },
            set: { binding.wrappedValue = $0 }
        )
    }
}

/// Window chrome SwiftUI doesn't expose: the titlebar separator.
private struct WindowChromeSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }

    // Re-applied on every update rather than once at mount, and again after
    // a hop: the split view isn't installed on the first pass.
    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.silenceTitlebarSeparators()
        DispatchQueue.main.async { view.silenceTitlebarSeparators() }
    }
}

private final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        silenceTitlebarSeparators()
        // The split view isn't built yet on the first pass through here.
        DispatchQueue.main.async { [weak self] in self?.silenceTitlebarSeparators() }
    }

    /// Silences AppKit's own hairline under the toolbar, which we draw in
    /// SwiftUI instead (`Hairline` at the top of the content and inspector
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

/// What a tab window shows: its tab of the selected workspace, or the
/// welcome screen when no workspace is selected.
private struct SlotContent: View {
    @EnvironmentObject private var state: AppState
    let slot: TabSlot

    var body: some View {
        if let id = slot.workspaceId, let ws = state.workspaceById(id) {
            TerminalArea(workspace: ws, workspaceState: state.workspaceState(for: id), slot: slot)
        } else {
            WelcomeView()
        }
    }
}
