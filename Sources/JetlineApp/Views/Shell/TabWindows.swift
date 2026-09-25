import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// One native window tab. Each tab in the strip is its own `NSWindow` in a
/// shared `NSWindowTabGroup` — AppKit draws the tab bar, the `+` button,
/// reordering, the close buttons and the tab context menu, the same way
/// Xcode and Ghostty get theirs.
///
/// Slots are positional: the Nth window in the group shows the Nth entry of
/// the selected workspace's `tabOrder`. Switching workspace reassigns the
/// existing windows instead of swapping whole window groups, so the frame,
/// the tab bar and the window's key status never move.
@MainActor
@Observable
final class TabSlot {
    /// Set right after init — the window's root view needs the slot first.
    /// The slot is what keeps its window alive; `retire()` breaks the
    /// cycles back to the slot through the window's root view and its tab
    /// accessory.
    @ObservationIgnored var window: TabWindow!
    @ObservationIgnored weak var split: TabSplitController?
    private(set) var workspaceId: String?
    /// `nil` stands in for "nothing to show": the welcome screen when no
    /// workspace is selected, or the empty moment before a freshly selected
    /// workspace spawns its first tab.
    private(set) var tab: TabRef?
    /// This slot's window is the group's selected (visible) tab.
    fileprivate(set) var isSelected = false
    /// Content mounts the first time the slot is selected and then stays
    /// mounted, so flipping back to a tab is instant. Reassigning the slot
    /// resets it — background slots don't mount terminals or chats for tabs
    /// the user never looks at, which keeps workspace hops cheap.
    fileprivate(set) var hasBeenShown = false
    /// Position in the strip; drives the ⌘N hint on the tab.
    fileprivate(set) var index = 0
    /// The toolbar's Merge asks for confirmation, which the tab's content
    /// presents.
    var pendingMerge = false
    /// Height of the chat composer's bar below its divider, while a chat
    /// is showing, so the inspector's merge footer can match it and the
    /// two dividers line up.
    var composerBarHeight: CGFloat?
    @ObservationIgnored fileprivate var toolbar: TabToolbar?

    fileprivate func retire() {
        guard let window else { return }
        window.contentViewController = nil
        window.tab.accessoryView = nil
        window.toolbar = nil
        toolbar?.invalidate()
        toolbar = nil
        window.slot = nil
        window.onNewTab = nil
        window.onMouseInteractionEnded = nil
        window.delegate = nil
        self.window = nil
    }

    fileprivate func assign(workspaceId: String?, tab: TabRef?) {
        guard self.workspaceId != workspaceId || self.tab != tab else { return }
        self.workspaceId = workspaceId
        self.tab = tab
        hasBeenShown = isSelected
    }
}

final class TabWindow: NSWindow {
    weak var slot: TabSlot?


    var onNewTab: (() -> Void)?
    /// A mouse interaction finished. Dragging a tab to reorder it runs the
    /// tab bar's tracking loop inside the mouse-down dispatch and posts no
    /// notification or KVO change, so this is where a reorder shows up.
    var onMouseInteractionEnded: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            onMouseInteractionEnded?()
        }
    }

    /// Implementing this is what makes AppKit show the `+` button at the end
    /// of the tab bar.
    override func newWindowForTab(_ sender: Any?) {
        onNewTab?()
    }
}

/// Owns the main window's tab group and keeps it in step with `AppState`:
/// the selected workspace's `tabOrder` drives which windows exist and what
/// each shows, `activeTab` drives the selected window. User actions on the
/// native tab bar (click, drag-reorder, close, `+`) flow back into
/// `AppState`, which then re-syncs.
@MainActor
final class MainWindowCoordinator: NSObject, NSWindowDelegate {
    private let state: AppState
    private let inspectorUI = InspectorUIState()
    /// Shared by every tab window, so switching tabs doesn't make the
    /// sidebar pop in or out. The inspector's counterpart is
    /// `AppState.inspectorVisible`.
    private var sidebarCollapsed = false
    /// Set while the coordinator itself collapses or expands panes, so the
    /// split controllers' collapse observers don't echo it back.
    private var applyingPanes = false

    /// In the group's display order after every sync.
    private var slots: [TabSlot] = []
    private var syncScheduled = false
    private var isSyncing = false
    /// Windows the coordinator itself is closing; their `windowShouldClose`
    /// must not route into `AppState.closeTab`.
    private var closingWindows: Set<ObjectIdentifier> = []
    private var cancellables: Set<AnyCancellable> = []
    private var groupObservations: [NSKeyValueObservation] = []
    private weak var observedGroup: NSWindowTabGroup?
    private var snapBackTimer: Timer?
    private var frameSaveScheduled = false

    /// Captured from the first root view — the coordinator has no SwiftUI
    /// environment of its own to open scene windows (onboarding) with.
    var openWindow: OpenWindowAction?

    private static let tabbingIdentifier = "jetline.main"
    private static let frameDefaultsKey = "JetlineMainWindowFrame"

    init(state: AppState) {
        self.state = state
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        // `NSWindow.allowsAutomaticWindowTabbing` stays on: turning it off
        // also disables `toggleTabBar`, so a single tab could never show the
        // bar. Other windows (Settings, Activity Log) have their own
        // tabbing identifiers and never merge into this group.
        MenuFirstShortcutMonitor.install()
        let slot = makeSlot()
        restoreFrame(of: slot.window)
        slots = [slot]
        slot.window.makeKeyAndOrderFront(nil)
        // A single-tab group hides the bar by default. Keep it up from the
        // start — the welcome screen included, as a "Jetline" tab — so the
        // strip and its `+` don't come and go with the tab count. From here
        // on, View → Hide Tab Bar is the user's call.
        if slot.window.tabGroup?.isTabBarVisible == false {
            slot.window.toggleTabBar(nil)
        }

        state.$selectedWorkspaceId
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        // The menu commands' enabled states key off these; see
        // `refreshMenuCommands`.
        Publishers.Merge4(
            state.$selectedWorkspaceId.map { _ in () },
            state.$navShortcutSuppressors.map { _ in () },
            state.$repositories.map { _ in () },
            state.$workspacesByRepo.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { Self.refreshMenuCommands() }
        .store(in: &cancellables)
        state.$inspectorVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPanes(animated: true) }
            .store(in: &cancellables)
        state.$settings
            .map(\.theme)
            .removeDuplicates()
            .sink { theme in
                switch theme {
                case .system: NSApp.appearance = nil
                case .light: NSApp.appearance = NSAppearance(named: .aqua)
                case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                }
            }
            .store(in: &cancellables)

        sync()

        Task {
            await state.load()
            // Open the welcome flow on the first launch after install (or
            // after the user clears the flag via the Debug menu). The
            // OnboardingView itself flips the flag the first time it
            // appears so a subsequent relaunch stays quiet.
            if !state.settings.hasCompletedOnboarding {
                openWindow?(id: "onboarding")
            }
        }
    }

    /// SwiftUI re-evaluates menu commands for its own scenes' windows; with
    /// the main window built in AppKit it only catches up when a menu
    /// updates. Until then key equivalents run against stale enabled
    /// states — ⌘T stays disabled after launch until the File menu is
    /// opened once. Nudge every menu's (SwiftUI-owned) delegate.
    private static func refreshMenuCommands() {
        for item in NSApp.mainMenu?.items ?? [] {
            guard let menu = item.submenu else { continue }
            menu.delegate?.menuNeedsUpdate?(menu)
        }
    }

    /// Dock click / Window menu with the main window closed.
    func showMainWindow() {
        let window = selectedSlot?.window ?? slots.first?.window
        window?.makeKeyAndOrderFront(nil)
    }

    func saveFrame() {
        guard let window = selectedSlot?.window else { return }
        UserDefaults.standard.set(window.frameDescriptor, forKey: Self.frameDefaultsKey)
    }

    // MARK: - Panes

    // Column floors. The content column reports this regardless of what's
    // in it, so the columns always fit the window.
    static let sidebarMinimum: CGFloat = 220
    static let contentMinimum: CGFloat = 320
    static let inspectorMinimum: CGFloat = 240

    /// Nothing to inspect on the welcome screen.
    var canShowInspector: Bool { state.selectedWorkspaceId != nil }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
        applyPanes(animated: true)
    }

    func toggleInspector() {
        guard canShowInspector else { return }
        state.inspectorVisible.toggle()
    }

    /// Puts every tab window's sidebar and inspector in the shared state.
    /// Only the visible tab animates; the others just follow.
    private func applyPanes(animated: Bool) {
        let inspectorCollapsed = !(state.inspectorVisible && canShowInspector)
        if !inspectorCollapsed, let window = selectedSlot?.window,
           selectedSlot?.split?.inspectorItem.isCollapsed == true {
            makeRoomForInspector(in: window)
        }
        applyingPanes = true
        defer { applyingPanes = false }
        for slot in slots {
            guard let split = slot.split else { continue }
            let animate = animated && slot.isSelected
            for (item, collapsed) in [(split.sidebarItem, sidebarCollapsed), (split.inspectorItem, inspectorCollapsed)]
            where item.isCollapsed != collapsed {
                if animate {
                    item.animator().isCollapsed = collapsed
                } else {
                    item.isCollapsed = collapsed
                }
            }
        }
    }

    /// AppKit won't expand a column that doesn't fit — the toggle would do
    /// nothing. Widen the window first, as Xcode does, staying on screen.
    private func makeRoomForInspector(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let split = window.contentViewController as? TabSplitController else { return }
        let sidebar = split.sidebarItem.isCollapsed ? 0 : split.sidebarItem.viewController.view.frame.width
        let needed = sidebar + Self.contentMinimum + max(Self.inspectorMinimum, split.inspectorItem.viewController.view.frame.width) + 2
        guard window.frame.width < needed else { return }
        var frame = window.frame
        frame.size.width = needed
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// A pane collapsed or expanded without the coordinator asking — a
    /// divider dragged shut, or AppKit collapsing it as the window shrank.
    /// Adopt it as the shared state.
    ///
    /// Only while the user is at it — dragging, or live-resizing the window.
    /// AppKit also collapses on its own while windows come and go, and that
    /// isn't a preference; the shared state is put back instead.
    func paneCollapseChanged(in split: TabSplitController) {
        guard !applyingPanes, let window = split.view.window,
              slot(for: window)?.isSelected == true else { return }
        guard NSEvent.pressedMouseButtons != 0 || window.inLiveResize else {
            DispatchQueue.main.async { [weak self] in self?.applyPanes(animated: false) }
            return
        }
        sidebarCollapsed = split.sidebarItem.isCollapsed
        if canShowInspector, state.inspectorVisible == split.inspectorItem.isCollapsed {
            state.inspectorVisible = !split.inspectorItem.isCollapsed
        }
        applyPanes(animated: false)
    }

    // MARK: - Windows

    private func makeSlot() -> TabSlot {
        let slot = TabSlot()
        let environment: (AnyView) -> AnyView = { [state, inspectorUI] view in
            AnyView(
                view
                    .environmentObject(state)
                    .environment(\.monoFontFamily, state.settings.monospaceFontFamily)
                    .environment(inspectorUI)
            )
        }
        let split = TabSplitController(slot: slot, state: state, coordinator: self, environment: environment)
        split.sidebarItem.isCollapsed = sidebarCollapsed
        split.inspectorItem.isCollapsed = !(state.inspectorVisible && canShowInspector)
        slot.split = split

        let window = TabWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        let toolbar = TabToolbar(slot: slot, state: state)
        slot.toolbar = toolbar
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        // All of the titlebar goes to the toolbar's items.
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.slot = slot
        window.onNewTab = { [weak self] in self?.newTabFromTabBar() }
        window.onMouseInteractionEnded = { [weak self] in self?.reconcileGroup() }
        let accessory = NSHostingView(rootView: TabAccessory(slot: slot))
        accessory.sizingOptions = [.intrinsicContentSize]
        window.tab.accessoryView = accessory
        slot.window = window
        return slot
    }

    private func restoreFrame(of window: NSWindow) {
        if let descriptor = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            window.setFrame(from: descriptor)
        } else {
            window.center()
        }
    }

    private var selectedSlot: TabSlot? {
        slots.first { $0.isSelected }
    }

    private func slot(for window: NSWindow?) -> TabSlot? {
        (window as? TabWindow)?.slot
    }

    /// The group's windows mapped back to slots, in display order.
    private func groupSlots() -> [TabSlot] {
        guard let anchor = slots.first?.window,
              let windows = anchor.tabGroup?.windows ?? anchor.tabbedWindows else {
            return slots
        }
        return windows.compactMap { slot(for: $0) }
    }

    // MARK: - Sync

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        // `@Published` fires in `willSet`, and several mutations tend to
        // land together (close + reselect); read them once they've settled.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.sync()
        }
    }

    private struct Desired {
        let workspaceId: String?
        let tabs: [TabRef?]
        let selectedIndex: Int
    }

    /// Reads the state the tab group mirrors. Tracked, so any change to the
    /// selected workspace's strip schedules the next sync.
    private func readDesired() -> Desired {
        withObservationTracking {
            guard let id = state.selectedWorkspaceId, state.workspaceById(id) != nil else {
                return Desired(workspaceId: nil, tabs: [nil], selectedIndex: 0)
            }
            let ws = state.workspaceState(for: id)
            let order = ws.tabOrder
            guard !order.isEmpty else {
                return Desired(workspaceId: id, tabs: [nil], selectedIndex: 0)
            }
            let selected = ws.activeTab.flatMap { order.firstIndex(of: $0) } ?? 0
            return Desired(workspaceId: id, tabs: order, selectedIndex: selected)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }
    }

    private func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let desired = readDesired()
        var current = groupSlots()
        let previouslySelected = selectedSlot
        let wasKey = previouslySelected?.window.isKeyWindow ?? false

        // Drop slots whose tab closed, keeping the rest in place so their
        // content doesn't remount. Only for the same workspace — across a
        // workspace switch every slot gets reassigned anyway.
        var removed: [TabSlot] = []
        if current.count > desired.tabs.count {
            let wanted = Set(desired.tabs.compactMap { $0 })
            for slot in current where current.count - removed.count > desired.tabs.count {
                let stale = slot.workspaceId != desired.workspaceId
                    || slot.tab.map { !wanted.contains($0) } ?? true
                if stale && slot !== previouslySelected { removed.append(slot) }
            }
            // Still too many (e.g. the selected slot was the stale one):
            // trim from the end.
            for slot in current.reversed() where current.count - removed.count > desired.tabs.count {
                if !removed.contains(where: { $0 === slot }) { removed.append(slot) }
            }
            current.removeAll { slot in removed.contains { $0 === slot } }
        }

        // Grow to fit, appending at the end of the strip.
        while current.count < desired.tabs.count {
            let slot = makeSlot()
            if let anchor = current.last?.window ?? removed.first?.window {
                anchor.addTabbedWindow(slot.window, ordered: .above)
            }
            current.append(slot)
        }

        for (i, slot) in current.enumerated() {
            slot.assign(workspaceId: desired.workspaceId, tab: desired.tabs[i])
            slot.index = i
            // A tab's own title comes from its content; an empty slot
            // (welcome screen, or a workspace mid-spawn) is named here.
            if desired.tabs[i] == nil {
                slot.window.tab.attributedTitle = nil
                slot.window.tab.title = desired.workspaceId.flatMap { state.workspaceById($0)?.name } ?? "Jetline"
            }
        }

        slots = current
        let target = current[desired.selectedIndex]
        select(target, from: previouslySelected, makeKey: wasKey)
        // The inspector follows the selection too (hidden on the welcome
        // screen).
        applyPanes(animated: false)

        for slot in removed {
            let window = slot.window!
            closingWindows.insert(ObjectIdentifier(window))
            window.close()
            closingWindows.remove(ObjectIdentifier(window))
            slot.retire()
        }

        observeGroup()
    }

    private func select(_ target: TabSlot, from previous: TabSlot?, makeKey: Bool) {
        for slot in slots {
            slot.isSelected = slot === target
            if slot.isSelected { slot.hasBeenShown = true }
        }
        let window = target.window!
        if window.tabGroup?.selectedWindow !== window {
            window.tabGroup?.selectedWindow = window
        }
        if makeKey, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if previous !== target, let source = previous?.window {
            scheduleSplitLayoutCopy(from: source, to: window)
        }
    }

    // MARK: - Tab group events

    /// Re-attach KVO whenever the group object changes (a window closing or
    /// tearing off can leave the survivors in a fresh group).
    private func observeGroup() {
        guard let group = slots.first?.window.tabGroup, group !== observedGroup else { return }
        observedGroup = group
        groupObservations = [
            group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.groupSelectionChanged() }
            },
            group.observe(\.windows, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcileGroup() }
            }
        ]
    }

    private func groupSelectionChanged() {
        guard !isSyncing,
              let window = observedGroup?.selectedWindow,
              let slot = slot(for: window),
              !slot.isSelected else { return }
        let previous = selectedSlot
        if let previous { scheduleSplitLayoutCopy(from: previous.window, to: window) }
        for s in slots {
            s.isSelected = s === slot
        }
        slot.hasBeenShown = true
        if let tab = slot.tab, let wsId = slot.workspaceId {
            state.selectTab(tab, in: wsId)
        }
    }

    /// Pick up what the user did to the group directly: a tab torn off, or
    /// the strip reordered.
    private func reconcileGroup() {
        guard !isSyncing, let group = observedGroup else { return }
        let inGroup = group.windows.compactMap { slot(for: $0) }
        // Torn off (dragged out of the bar, or "Move Tab to New Window"):
        // put it back once the drag ends. Jetline has one window per app;
        // a stray tab window would show a workspace the sidebar isn't on.
        let strays = slots.filter { slot in
            !inGroup.contains { $0 === slot } && !closingWindows.contains(ObjectIdentifier(slot.window))
        }
        if !strays.isEmpty {
            scheduleSnapBack()
            return
        }
        // Drag-reordered in the bar.
        guard inGroup.count == slots.count,
              let wsId = slots.first?.workspaceId else { return }
        let order = inGroup.compactMap(\.tab)
        slots = inGroup
        for (i, slot) in inGroup.enumerated() { slot.index = i }
        if order.count == inGroup.count, order != state.workspaceState(for: wsId).tabOrder {
            state.setTabOrder(order, in: wsId)
        }
    }

    private func scheduleSnapBack() {
        guard snapBackTimer == nil else { return }
        snapBackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                self.snapBackTimer?.invalidate()
                self.snapBackTimer = nil
                self.snapBack()
            }
        }
    }

    /// `slots` still holds the pre-tear-off order (reconciling bails while a
    /// stray exists), so each stray goes back beside its old neighbour and
    /// stays the selected tab — the user was just dragging it.
    private func snapBack() {
        guard let anchor = slots.first(where: { $0.window.tabGroup === observedGroup })?.window
                ?? slots.first?.window else { return }
        var placed = Set((anchor.tabGroup?.windows ?? [anchor]).map(ObjectIdentifier.init))
        var lastStray: TabSlot?
        for (i, slot) in slots.enumerated() where !placed.contains(ObjectIdentifier(slot.window)) {
            let window = slot.window!
            let frame = anchor.frame
            if let before = slots[..<i].last(where: { placed.contains(ObjectIdentifier($0.window)) }) {
                before.window.addTabbedWindow(window, ordered: .above)
            } else if let after = slots[(i + 1)...].first(where: { placed.contains(ObjectIdentifier($0.window)) }) {
                after.window.addTabbedWindow(window, ordered: .below)
            }
            window.setFrame(frame, display: false)
            placed.insert(ObjectIdentifier(window))
            lastStray = slot
        }
        observedGroup = nil
        if let tab = lastStray?.tab, let wsId = lastStray?.workspaceId {
            state.selectTab(tab, in: wsId)
        }
        sync()
    }

    private func newTabFromTabBar() {
        guard let id = state.selectedWorkspaceId else { return }
        state.openLauncherTab(in: id)
    }

    // MARK: - NSWindowDelegate

    /// A tab's close button, the red traffic light and File → Close all land
    /// here. Close the tab through `AppState` and let the sync remove the
    /// window; with nothing to close (welcome screen), just hide the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingWindows.contains(ObjectIdentifier(sender)) { return true }
        guard let slot = slot(for: sender) else { return true }
        if let tab = slot.tab, let wsId = slot.workspaceId {
            state.closeTab(tab, in: wsId)
        } else {
            saveFrame()
            for s in slots { s.window.orderOut(nil) }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Backstop for selection changes the KVO misses (e.g. Window menu).
        guard let window = notification.object as? TabWindow,
              window.tabGroup?.selectedWindow === window else { return }
        groupSelectionChanged()
    }

    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }

    private func scheduleFrameSave() {
        guard !frameSaveScheduled else { return }
        frameSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.frameSaveScheduled = false
            self?.saveFrame()
        }
    }

    // MARK: - Split layout

    /// Each tab window has its own `NavigationSplitView`, so a column the
    /// user resized in one tab would snap back when they switch to another.
    /// Carry the divider positions across as the selection moves. Deferred
    /// until the target is the visible tab: the selection change can arrive
    /// mid-layout (AppKit swaps tab windows inside its own display cycle),
    /// and moving a divider from there throws.
    private func scheduleSplitLayoutCopy(from source: NSWindow, to target: NSWindow) {
        DispatchQueue.main.async { [weak self, weak source, weak target] in
            guard let self, let source, let target,
                  target.tabGroup?.selectedWindow === target else { return }
            self.copySplitLayout(from: source, to: target)
        }
    }

    private func copySplitLayout(from source: NSWindow, to target: NSWindow) {
        guard let from = source.contentView, let to = target.contentView else { return }
        let sourceSplits = Self.splitViews(in: from)
        let targetSplits = Self.splitViews(in: to)
        guard sourceSplits.count == targetSplits.count else { return }
        for (s, t) in zip(sourceSplits, targetSplits) {
            let sv = s.arrangedSubviews, tv = t.arrangedSubviews
            guard sv.count == tv.count, sv.count > 1 else { continue }
            for i in 0..<(sv.count - 1) where !sv[i].isHidden && !tv[i].isHidden {
                let position = s.isVertical ? sv[i].frame.maxX : sv[i].frame.maxY
                let current = t.isVertical ? tv[i].frame.maxX : tv[i].frame.maxY
                if abs(position - current) > 0.5 {
                    t.setPosition(position, ofDividerAt: i)
                }
            }
        }
    }

    private static func splitViews(in view: NSView) -> [NSSplitView] {
        var result: [NSSplitView] = []
        func walk(_ v: NSView) {
            if let split = v as? NSSplitView { result.append(split) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return result
    }
}

/// Right-aligned tab accessory: the chat's activity dot and the ⌘N hint,
/// as Ghostty shows it.
private struct TabAccessory: View {
    let slot: TabSlot

    var body: some View {
        HStack(spacing: 6) {
            if let chat {
                ChatActivityDot(activity: chat.activity)
            }
            if slot.tab != nil, slot.index < 9 {
                Text("⌘\(slot.index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private var chat: ChatSession? {
        guard case .chat(let id) = slot.tab, let wsId = slot.workspaceId else { return nil }
        return AppState.shared.workspaceState(for: wsId).chats.first { $0.id == id }
    }
}

/// What the agent in a chat tab is doing, as a dot beside the tab's title.
struct ChatActivityDot: View {
    let activity: ChatSession.Activity

    var body: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .working:
            PulsingDot(color: .accentColor)
        case .needsInput:
            dot(.orange)
        case .failed:
            dot(.red)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// A tab's title in the native bar: an icon (agent mark or file icon) and
/// its name. Built as an attributed string because `NSWindowTab` has no
/// image property; a text attachment renders inline.
enum TabTitle {
    @MainActor
    static func attributed(icon: NSImage?, title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let icon {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(string: title))
        return result
    }

    /// Finder's document icon for the file's type, cached per extension.
    /// Looked up by type rather than by path so a deleted file still gets
    /// its icon.
    @MainActor private static var fileIconCache: [String: NSImage] = [:]

    @MainActor static func fileIcon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let cached = fileIconCache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .plainText
        let icon = NSWorkspace.shared.icon(for: type)
        fileIconCache[ext] = icon
        return icon
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
enum MenuFirstShortcutMonitor {
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

extension EnvironmentValues {
    /// The tab window a view is in, for views that share state across its
    /// columns.
    @Entry var tabSlot: TabSlot?
}
