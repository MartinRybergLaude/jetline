import AppKit
import Combine
import SwiftUI

/// A tab window's toolbar, built in AppKit the way Xcode builds its own:
/// a fixed set of items for the window's life, whose images, titles and
/// menus are updated in place as the workspace changes.
///
/// Not SwiftUI's bridged `.toolbar`: SwiftUI replaces the whole toolbar
/// whenever the view declaring it re-renders — switching inspector tabs is
/// enough — which throws away the sidebar / inspector section items, and
/// the toolbar visibly re-lays out on every rebuild.
@MainActor
final class TabToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate {
    let toolbar = NSToolbar(identifier: "jetline.tab")

    private let slot: TabSlot
    private let state: AppState

    private var title: NSToolbarItem?
    private var git: NSMenuToolbarItem?
    private var gitBusy: NSToolbarItem?
    private var openIn: NSMenuToolbarItem?
    private var run: NSToolbarItem?
    private var runBusy: NSToolbarItem?

    private var cancellables: Set<AnyCancellable> = []
    private var controllerCancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private var pulseTimer: Timer?
    private var pulseDim = false

    private static let titleID = NSToolbarItem.Identifier("jetline.title")
    private static let gitID = NSToolbarItem.Identifier("jetline.git")
    private static let gitBusyID = NSToolbarItem.Identifier("jetline.gitBusy")
    private static let openInID = NSToolbarItem.Identifier("jetline.openIn")
    private static let runID = NSToolbarItem.Identifier("jetline.run")
    private static let runBusyID = NSToolbarItem.Identifier("jetline.runBusy")

    init(slot: TabSlot, state: AppState, environment: @escaping (AnyView) -> AnyView) {
        self.slot = slot
        self.state = state
        self.environment = environment
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false

        state.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        refresh()
    }

    private let environment: (AnyView) -> AnyView

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator,
            Self.titleID, .flexibleSpace,
            Self.gitID, Self.gitBusyID, Self.openInID, Self.runID, Self.runBusyID,
            .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case Self.titleID:
            item = NSToolbarItem(itemIdentifier: id)
            let host = NSHostingView(rootView: environment(AnyView(WorkspaceTitleItem(slot: slot))))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            // Text, not a control: no glass capsule.
            item.isBordered = false
            title = item
        case Self.gitID:
            let menuItem = menuItem(id, label: "Git", action: #selector(triggerPrimaryGitAction))
            git = menuItem
            item = menuItem
        case Self.openInID:
            let menuItem = menuItem(id, label: "Open In", action: #selector(openInCurrentApp))
            openIn = menuItem
            item = menuItem
        case Self.runID:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = "Run"
            item.target = self
            item.action = #selector(toggleRun)
            run = item
        case Self.gitBusyID, Self.runBusyID:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = BusyLabel()
            if id == Self.gitBusyID { gitBusy = item } else { runBusy = item }
        default:
            return NSToolbarItem(itemIdentifier: id)
        }
        scheduleRefresh()
        return item
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, label: String, action: Selector) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = label
        item.target = self
        item.action = action
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        return item
    }

    // MARK: - State

    private var workspace: Workspace? {
        slot.workspaceId.flatMap(state.workspaceById)
    }

    /// Coalesces a burst of `AppState` changes into one pass, after they've
    /// landed (`objectWillChange` fires before the new value is set).
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            refresh()
        }
    }

    /// Puts the current workspace into the items. Only assigns what changed,
    /// so a pass with nothing new costs no layout.
    private func refresh() {
        controllerCancellables.removeAll()
        // Everything the pass reads from `@Observable` state: the slot (the
        // coordinator reassigns it after `AppState` changes) and the
        // workspace's state.
        let (workspace, ws) = withObservationTracking {
            let workspace = self.workspace
            let ws = workspace.map { state.workspaceState(for: $0.id) }
            if let ws {
                _ = (ws.diff, ws.pr, ws.hasUncommitted, ws.branchPosition, ws.runningGitAction,
                     ws.setupController, ws.runController)
            }
            return (workspace, ws)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }

        // For the Window menu and the Dock; the title item shows it here.
        let windowTitle = workspace?.name ?? "Jetline"
        if let window = slot.window, window.title != windowTitle { window.title = windowTitle }
        guard let workspace, let ws else {
            for item in [title, git, gitBusy, openIn, run, runBusy] {
                item?.setHiddenIfNeeded(true)
            }
            stopPulse()
            return
        }

        title?.setHiddenIfNeeded(false)

        refreshGit(workspace: workspace, ws: ws)
        refreshOpenIn()
        refreshRun(workspace: workspace, ws: ws)
    }

    private func refreshGit(workspace: Workspace, ws: WorkspaceState) {
        if let running = ws.runningGitAction {
            git?.setHiddenIfNeeded(true)
            gitBusy?.setHiddenIfNeeded(false)
            (gitBusy?.view as? BusyLabel)?.text = Self.runningText(for: running)
            gitBusy?.toolTip = Self.runningHelp(for: running, workspace: workspace)
            return
        }
        gitBusy?.setHiddenIfNeeded(true)
        let actions = gitActionState(ws)
        guard let git, actions.isVisible else {
            self.git?.setHiddenIfNeeded(true)
            return
        }
        git.setHiddenIfNeeded(false)
        let primary = actions.primary
        git.setTitleIfNeeded(primary?.displayName ?? "Git")
        git.setImageIfNeeded(primary?.systemImage ?? "arrow.triangle.branch")
        // Nothing actionable: the whole button opens the menu, to show why.
        git.action = primary == nil ? nil : #selector(triggerPrimaryGitAction)
        git.toolTip = Self.gitHelp(primary: primary, workspace: workspace)
    }

    private func refreshOpenIn() {
        guard let openIn else { return }
        openIn.setHiddenIfNeeded(false)
        let app = currentOpenInApp
        openIn.setTitleIfNeeded(app.displayName)
        if openIn.image !== app.icon(size: 14) {
            openIn.image = app.icon(size: 14)
        }
        openIn.toolTip = "Open workspace in \(app.displayName)"
    }

    private func refreshRun(workspace: Workspace, ws: WorkspaceState) {
        if let setup = ws.setupController {
            setup.objectWillChange
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &controllerCancellables)
            if setup.isRunning {
                run?.setHiddenIfNeeded(true)
                runBusy?.setHiddenIfNeeded(false)
                (runBusy?.view as? BusyLabel)?.text = "Setting up"
                runBusy?.toolTip = "Setup is running. Run will be available once setup completes."
                stopPulse()
                return
            }
        }
        runBusy?.setHiddenIfNeeded(true)
        guard let run, state.hasRunScript(workspace) else {
            self.run?.setHiddenIfNeeded(true)
            stopPulse()
            return
        }
        run.setHiddenIfNeeded(false)
        let phase = ws.runController?.phase ?? .idle
        if let runner = ws.runController {
            runner.objectWillChange
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &controllerCancellables)
        }
        switch phase {
        case .queued, .starting: startPulse()
        case .idle, .running: stopPulse()
        }
        run.image = RunImage.image(phase: phase, dimmed: pulseDim)
        run.toolTip = switch phase {
        case .idle: "Run the configured run script"
        case .queued: "Waiting for the other run to stop… click to cancel"
        case .starting: "Starting… click to stop"
        case .running: "Running — click to stop"
        }
    }

    /// The pulsing dot while a run spins up.
    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pulseDim.toggle()
                self.scheduleRefresh()
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseDim = false
    }

    func invalidate() {
        stopPulse()
        cancellables.removeAll()
        controllerCancellables.removeAll()
    }

    private func gitActionState(_ ws: WorkspaceState) -> GitActionState {
        GitActionState.derive(
            diff: ws.diff,
            pr: ws.pr,
            hasUncommitted: ws.hasUncommitted,
            branchPosition: ws.branchPosition
        )
    }

    /// Falls back to Finder if the persisted choice was uninstalled since
    /// it was saved — Finder is always present.
    private var currentOpenInApp: OpenInApp {
        let stored = state.settings.defaultOpenInApp
        return stored.isInstalled ? stored : .finder
    }

    // MARK: - Menus

    /// Menus are built as they open, from the state at that moment.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let workspace else { return }
        switch menu {
        case git?.menu: buildGitMenu(menu, workspace: workspace)
        case openIn?.menu: buildOpenInMenu(menu)
        default: break
        }
    }

    private func buildGitMenu(_ menu: NSMenu, workspace: Workspace) {
        let actions = gitActionState(state.workspaceState(for: workspace.id))
        for action in GitAction.allCases where action != actions.primary {
            let item = ActionMenuItem(action.displayName) { [weak self] in self?.trigger(action) }
            item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            item.isEnabled = actions.isAvailable(action)
            menu.addItem(item)
        }
    }

    private func buildOpenInMenu(_ menu: NSMenu) {
        for app in OpenInApp.allCases where app.isInstalled {
            let item = ActionMenuItem(app.displayName) { [weak self] in
                guard let self else { return }
                var settings = state.settings
                settings.defaultOpenInApp = app
                state.saveSettings(settings)
                if let ws = workspace { app.open(directory: ws.worktreePath) }
            }
            item.image = app.icon(size: 16)
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func triggerPrimaryGitAction() {
        guard let ws = workspace, let primary = gitActionState(state.workspaceState(for: ws.id)).primary else { return }
        trigger(primary)
    }

    private func trigger(_ action: GitAction) {
        guard let ws = workspace else { return }
        switch action {
        case .mergePR:
            // The confirmation is SwiftUI's, on the tab's content.
            slot.pendingMerge = true
        case .rebaseOnMain:
            // Fast path: try a clean `git rebase` first to avoid spinning up
            // an agent (and burning tokens) when there are no conflicts. The
            // agent flow takes over automatically on any failure.
            Task { await state.performRebase(for: ws) }
        case .pullUpdates:
            // Same fast-path treatment as rebase — the common no-conflict
            // case is just `git pull --rebase --autostash`.
            Task { await state.performPull(for: ws) }
        default:
            state.startGitActionSession(for: ws, action: action)
        }
    }

    @objc private func openInCurrentApp() {
        guard let ws = workspace else { return }
        currentOpenInApp.open(directory: ws.worktreePath)
    }

    @objc private func toggleRun() {
        guard let ws = workspace else { return }
        state.toggleRun(for: ws)
    }

    // MARK: - Text

    private static func runningText(for action: GitAction) -> String {
        switch action {
        case .rebaseOnMain: return "Rebasing"
        case .pullUpdates:  return "Pulling"
        case .mergePR:      return "Merging"
        default:            return action.displayName
        }
    }

    private static func runningHelp(for action: GitAction, workspace: Workspace) -> String {
        switch action {
        case .rebaseOnMain: return "Rebasing onto \(workspace.baseBranch)…"
        case .pullUpdates:  return "Pulling from origin/\(workspace.branchName)…"
        case .mergePR:      return "Merging the pull request…"
        default:            return "\(action.displayName)…"
        }
    }

    private static func gitHelp(primary: GitAction?, workspace: Workspace) -> String {
        guard let primary else { return "Git actions — nothing actionable right now" }
        switch primary {
        case .commit:        return "Commit uncommitted changes with the git agent"
        case .createPR:      return "Push and open a pull request"
        case .pullUpdates:   return "Pull commits from origin/\(workspace.branchName) (rebase)"
        case .rebaseOnMain:  return "Rebase this branch onto \(workspace.baseBranch) and force-push (with lease)"
        case .fixCI:         return "Investigate and fix failing CI checks"
        case .fixComments:   return "Fix open PR comments"
        case .mergePR:       return "Merge the pull request"
        case .review:        return "Run a code review with the review agent"
        }
    }
}

private extension NSToolbarItem {
    func setHiddenIfNeeded(_ hidden: Bool) {
        if isHidden != hidden { isHidden = hidden }
    }
}

private extension NSMenuToolbarItem {
    func setTitleIfNeeded(_ value: String) {
        if title != value { title = value }
    }

    func setImageIfNeeded(_ symbol: String) {
        guard image?.accessibilityDescription != symbol else { return }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// Spinner and text for an action in flight — "Setting up", "Rebasing".
private final class BusyLabel: NSStackView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue } }
    }

    init() {
        super.init(frame: .zero)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.textColor = .secondaryLabelColor
        orientation = .horizontal
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        addArrangedSubview(spinner)
        addArrangedSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The run button's symbol: play when idle, stop otherwise, with a status
/// dot — yellow while spinning up, green once running.
@MainActor
private enum RunImage {
    private static var cache: [String: NSImage] = [:]

    static func image(phase: RunController.Phase, dimmed: Bool) -> NSImage? {
        let key = "\(phase)-\(dimmed)"
        if let hit = cache[key] { return hit }
        guard let symbol = NSImage(
            systemSymbolName: phase == .idle ? "play" : "stop",
            accessibilityDescription: phase == .idle ? "Run" : "Stop"
        ) else { return nil }
        let dot: NSColor? = switch phase {
        case .idle: nil
        case .queued, .starting: NSColor.systemYellow.withAlphaComponent(dimmed ? 0.35 : 1)
        case .running: .readableGreen
        }
        guard let dot else {
            cache[key] = symbol
            return symbol
        }
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { rect in
            // Not a template once the dot is in, so tint the symbol here.
            let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? symbol
            tinted.draw(in: rect)
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - 3, y: size.height - 3, width: 6, height: 6)).fill()
            return true
        }
        cache[key] = image
        return image
    }
}

/// Workspace name over its branch and diff stats, where the window title
/// would be.
private struct WorkspaceTitleItem: View {
    @EnvironmentObject private var state: AppState
    let slot: TabSlot

    var body: some View {
        if let id = slot.workspaceId, let workspace = state.workspaceById(id) {
            WorkspaceTitleBar(
                name: workspace.name,
                branch: workspace.branchName,
                stats: state.workspaceState(for: id).diff
            )
        } else {
            // Something to measure while the item is hidden.
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// Matches the system title styling — name in headline weight on top,
/// branch in secondary subheadline below — and adds a coloured diff pill
/// alongside the branch.
private struct WorkspaceTitleBar: View {
    let name: String
    let branch: String
    let stats: DiffSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Text(branch)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let stats, !stats.isEmpty {
                    ChangesPill(adds: stats.totalAdditions, dels: stats.totalDeletions)
                }
            }
        }
        .padding(.leading, 8)
    }
}

private struct ChangesPill: View {
    let adds: Int
    let dels: Int

    var body: some View {
        HStack(spacing: 4) {
            if adds > 0 {
                Text("+\(adds)").foregroundStyle(Color.readableGreen)
            }
            if dels > 0 {
                Text("−\(dels)").foregroundStyle(.red)
            }
        }
        .monoFont(size: 11, weight: .medium)
    }
}
