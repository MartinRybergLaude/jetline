#if os(macOS)
import Foundation
import SwiftUI
import AppKit

/// Root observable state of the app — the client side of Jetline.
///
/// Everything durable or process-backed (repositories, worktrees, agents,
/// terminals, git, the database) belongs to the engine, which runs either in
/// this process or as `jetlined` on another machine; see `EngineConnection`.
/// AppState mirrors it from the engine's events and turns user actions into
/// requests. What stays here is purely presentation: selection, the tab
/// strip's order and active tab, diff and new-tab pages, the inspector.
///
/// Per-workspace state lives in `WorkspaceState` instances looked up via
/// `workspaceState(for:)`, *not* in dicts on this object. That split keeps a
/// single workspace's poll/diff update from invalidating every view in the
/// app via the shared `@Published` surface. `WorkspaceState` itself uses
/// `@Observable` so SwiftUI tracks reads per-keypath.
@MainActor
final class AppState: ObservableObject {
    nonisolated private static let repositoryBaseWorkspacePrefix = Engine.repositoryBaseWorkspacePrefix

    /// The app's one state object. Shared rather than scene-owned because
    /// the main window is built in AppKit (`MainWindowCoordinator`) at
    /// launch, before any SwiftUI scene would have created it.
    static let shared = AppState()

    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var workspacesByRepo: [String: [Workspace]] = [:]
    /// Immediate selection used by the sidebar, terminal, toolbar, and commands.
    @Published var selectedWorkspaceId: String?
    /// Lagging selection used by the inspector so heavy right-column panels
    /// don't rebuild in the same pass as terminal/workspace navigation.
    @Published var inspectorWorkspaceId: String?
    @Published private(set) var settings: AppSettings = AppSettings() {
        willSet { FontSettings.shared.apply(newValue) }
    }
    /// Per-repo GitHub metadata (owner/name + allowed merge methods).
    @Published private(set) var repoMetadataByRepo: [String: RepoIdentifier] = [:]
    @Published private(set) var prTrackerStatus: PRTrackerStatus = .ok
    @Published var inspectorVisible: Bool = true
    /// Active inspector tab. Lifted out of `InspectorView` so workspace
    /// creation can flip it to `.run` and surface live setup-script output.
    @Published var inspectorTab: InspectorTab = .changes
    /// Repo whose settings sheet should be presented at the shell level.
    @Published var repoPendingSettings: Repository?
    /// Repo whose workspace-creation sheet should be presented at shell level.
    @Published var repoPendingWorkspaceCreation: Repository?
    /// Surfaces that currently want the ⌘⇧ navigation key equivalents
    /// released back to the text system.
    @Published private(set) var navShortcutSuppressors: Set<String> = []
    /// Whether the mirror is current: false before the first sync and while
    /// a remote link is down.
    @Published private(set) var isSynced = false

    var navShortcutsSuppressed: Bool { !navShortcutSuppressors.isEmpty }

    func setNavShortcutsSuppressed(_ suppressed: Bool, by id: String) {
        if suppressed {
            navShortcutSuppressors.insert(id)
        } else {
            navShortcutSuppressors.remove(id)
        }
    }

    let connection: EngineConnection

    /// The ssh host of a remote engine reached over plain ssh.
    var remoteSSHHost: String? {
        if case let .remote(remote) = connection.target { return remote.sshHost }
        return nil
    }
    private(set) lazy var prTracker = PRTrackerProxy(connection: connection)
    private(set) lazy var conversationStore = PRConversationStore(connection: connection)
    /// The engine's activity log, mirrored.
    let activityLog = ActivityLog()

    private var workspaceStates: [String: WorkspaceState] = [:]
    private var workspaceActivationTask: Task<Void, Never>?
    private var inspectorSelectionTask: Task<Void, Never>?
    /// Selection recency, most recent last. Drives where selection lands
    /// when the selected workspace closes.
    private var selectionHistory: [String] = []
    /// Where a tab being opened should go in the strip, until it shows up.
    private var pendingPlacements: [TabRef: TabRef] = [:]
    /// Tabs closed here whose removal the engine hasn't confirmed yet, so a
    /// status already in flight doesn't bring them back.
    private var closingTabs: [String: String] = [:]
    private var hasLoaded = false

    init() {
        connection = EngineConnection(target: EngineConnection.savedTarget())
        EngineFiles.shared.bind(connection)
        connection.onConnected = { [weak self] client, hello in
            self?.didConnect(client, hello)
        }
        connection.onDisconnected = { [weak self] in
            self?.didDisconnect()
        }
    }

    /// Get-or-create the `WorkspaceState` for `id`.
    func workspaceState(for id: String) -> WorkspaceState {
        if let existing = workspaceStates[id] { return existing }
        let new = WorkspaceState(id: id)
        workspaceStates[id] = new
        return new
    }

    // MARK: - Load & sync

    /// Idempotent. Driven by `MainWindowCoordinator.start()` once the main
    /// window is up.
    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        connection.connect()
        // Hold the caller (window setup, onboarding) until the first sync —
        // settings come with it — but not for a remote host that's down.
        let deadline = Date().addingTimeInterval(15)
        while !isSynced, Date() < deadline {
            switch connection.status {
            case .failed, .reconnecting: return
            default: try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// Point the app at another engine.
    func switchEngine(to target: EngineTarget) {
        guard target != connection.target else { return }
        resetMirror()
        connection.switchTarget(target)
    }

    private func didConnect(_ client: EngineClient, _ hello: API.HelloResult) {
        client.onEvent = { [weak self] event in self?.handle(event) }
        // What this client already had open; new tabs from the snapshot
        // attach and subscribe as they're created.
        let existingSessions = workspaceStates.values.flatMap(\.sessions).map(ObjectIdentifier.init)
        let existingChats = workspaceStates.values.flatMap(\.chats).map(ObjectIdentifier.init)
        let snapshot = hello.snapshot
        applyGlobal(snapshot.global)
        for (id, diff) in snapshot.diffs { applyDiff(diff, to: id) }
        for (id, pr) in snapshot.prs { applyPRSnapshot(pr, to: id) }
        for (id, conversation) in snapshot.conversations { workspaceState(for: id).conversation = conversation }
        for (id, status) in snapshot.statuses { applyStatus(status, to: id) }
        // Workspaces the engine no longer runs anything in (a restarted
        // daemon, say) lose their local runtime here.
        for id in workspaceStates.keys where snapshot.statuses[id] == nil {
            applyStatus(Self.emptyStatus, to: id)
        }
        activityLog.clear()
        for event in snapshot.activity { activityLog.append(event) }
        // Resume what this client had open.
        let resumeSessions = Set(existingSessions)
        let resumeChats = Set(existingChats)
        for ws in workspaceStates.values {
            for session in ws.sessions where resumeSessions.contains(ObjectIdentifier(session)) { session.attach() }
            for chat in ws.chats where resumeChats.contains(ObjectIdentifier(chat)) { chat.subscribe() }
            ws.runController?.reattach()
            ws.setupController?.reattach()
        }
        isSynced = true
        if let id = selectedWorkspaceId {
            if workspaceById(id) == nil {
                clearSelectedWorkspace()
            } else {
                connection.send(API.SetFocus(workspaceId: id))
                activateSelectedWorkspace(id)
            }
        }
        #if DEBUG
        applyDebugLaunchArguments()
        #endif
    }

    private func didDisconnect() {
        isSynced = false
        for ws in workspaceStates.values {
            for chat in ws.chats { chat.markStale() }
        }
    }

    /// Forget everything mirrored from the current engine.
    private func resetMirror() {
        for ws in workspaceStates.values {
            tearDownLocalRuntime(ws)
        }
        workspaceStates.removeAll()
        repositories = []
        workspacesByRepo = [:]
        repoMetadataByRepo = [:]
        selectionHistory.removeAll()
        pendingPlacements.removeAll()
        closingTabs.removeAll()
        clearSelectedWorkspace()
        activityLog.clear()
        isSynced = false
    }

    private static let emptyStatus = WorkspaceStatus(
        branchPosition: BranchPosition(), runningGitAction: nil, isTogglingAutoMerge: false,
        isRefreshingPR: false, terminals: [], chats: [], setup: nil, run: nil, isOpen: false
    )

    private func handle(_ event: EngineEvent) {
        switch event {
        case let .global(snapshot):
            applyGlobal(snapshot)
        case let .workspaceDiff(id, diff):
            applyDiff(diff, to: id)
        case let .workspacePR(id, pr):
            applyPRSnapshot(pr, to: id)
        case let .workspaceConversation(id, conversation):
            let ws = workspaceState(for: id)
            if ws.conversation != conversation { ws.conversation = conversation }
        case let .workspaceStatus(id, status):
            applyStatus(status, to: id)
        case let .workspaceRemoved(id):
            if let ws = workspaceStates.removeValue(forKey: id) {
                tearDownLocalRuntime(ws)
            }
            if selectedWorkspaceId == id { reassignSelection(afterClosing: id) }
            selectionHistory.removeAll { $0 == id }
        case let .chat(id, patch):
            for ws in workspaceStates.values {
                if let chat = ws.chats.first(where: { $0.id == id }) {
                    chat.apply(patch)
                    break
                }
            }
        case let .activity(event):
            activityLog.append(event)
        case let .attention(_, _, critical):
            // Bounce the dock when Jetline isn't frontmost so a long run
            // doesn't go unnoticed.
            if !NSApp.isActive {
                NSApp.requestUserAttention(critical ? .criticalRequest : .informationalRequest)
            }
        case let .error(message):
            Task { await presentError(message) }
        }
    }

    private func applyGlobal(_ snapshot: GlobalSnapshot) {
        if repositories != snapshot.repositories { repositories = snapshot.repositories }
        if workspacesByRepo != snapshot.workspacesByRepo { workspacesByRepo = snapshot.workspacesByRepo }
        // While a save is in flight the engine's echo of an older value
        // mustn't overwrite newer local edits (a prompt being typed).
        if pendingSettingsSaves == 0, settings != snapshot.settings {
            let old = settings
            settings = snapshot.settings
            if old.monospaceFontFamily != settings.monospaceFontFamily || old.terminalFontSize != settings.terminalFontSize {
                applyTerminalFont(settings)
            }
        }
        if repoMetadataByRepo != snapshot.repoMetadataByRepo { repoMetadataByRepo = snapshot.repoMetadataByRepo }
        if prTrackerStatus != snapshot.prTrackerStatus { prTrackerStatus = snapshot.prTrackerStatus }
        for (provider, windows) in snapshot.rateLimits {
            AgentRateLimits.shared.merge(windows, for: provider)
        }
        // A workspace that vanished (deleted elsewhere, worktree missing)
        // takes the selection with it.
        if let id = selectedWorkspaceId, workspaceById(id) == nil {
            reassignSelection(afterClosing: id)
        }
    }

    private func applyDiff(_ state: WorkspaceDiffState, to id: String) {
        let ws = workspaceState(for: id)
        if ws.diff != state.diff { ws.diff = state.diff }
        if ws.localDiff != state.localDiff { ws.localDiff = state.localDiff }
        if ws.hasUncommitted != state.hasUncommitted { ws.hasUncommitted = state.hasUncommitted }
    }

    private func applyPRSnapshot(_ pr: PRSnapshot, to id: String) {
        let ws = workspaceState(for: id)
        if ws.pr != pr { ws.pr = pr }
    }

    /// Reconcile a workspace's tabs and runtime with the engine's view.
    private func applyStatus(_ status: WorkspaceStatus, to id: String) {
        let ws = workspaceState(for: id)
        if ws.branchPosition != status.branchPosition { ws.branchPosition = status.branchPosition }
        if ws.runningGitAction != status.runningGitAction { ws.runningGitAction = status.runningGitAction }
        if ws.isTogglingAutoMerge != status.isTogglingAutoMerge { ws.isTogglingAutoMerge = status.isTogglingAutoMerge }
        if ws.isRefreshingPR != status.isRefreshingPR { ws.isRefreshingPR = status.isRefreshingPR }
        let hadTabs = ws.hasAgentTabs

        // A tab closed here stays closed; once the engine stops listing it,
        // forget it was closing.
        let listed = Set(status.terminals.map(\.id) + status.chats.map(\.id))
        for (tabId, workspaceId) in closingTabs where workspaceId == id && !listed.contains(tabId) {
            closingTabs.removeValue(forKey: tabId)
        }
        let closingHere = Set(closingTabs.keys)

        // Terminals
        let terminalIds = Set(status.terminals.map(\.id))
        for info in status.terminals where !closingHere.contains(info.id) {
            ensureSession(info, in: ws)
        }
        for session in ws.sessions where !terminalIds.contains(session.id) {
            dropSession(session, from: ws)
        }

        // Chats
        let chatIds = Set(status.chats.map(\.id))
        for summary in status.chats where !closingHere.contains(summary.id) {
            ensureChat(summary, in: ws)
        }
        for chat in ws.chats where !chatIds.contains(chat.id) {
            dropChat(chat, from: ws)
        }

        // Setup / run
        if let setup = status.setup {
            let controller = ws.setupController ?? SetupController(workspaceId: id, connection: connection)
            ws.setupController = controller
            controller.apply(setup)
        } else if let controller = ws.setupController {
            controller.discard()
            ws.setupController = nil
        }
        if let run = status.run {
            let controller = ws.runController ?? RunController(workspaceId: id, connection: connection)
            ws.runController = controller
            controller.apply(run)
        } else if let controller = ws.runController {
            controller.discard()
            ws.runController = nil
        }

        // The last tab closed engine-side (another client, or the workspace
        // was closed): leave it like a closed workspace.
        if hadTabs, !ws.hasAgentTabs, !status.isOpen {
            ws.diffTabs.removeAll()
            ws.tabOrder.removeAll()
            ws.activeTab = nil
            if selectedWorkspaceId == id { reassignSelection(afterClosing: id) }
        }
        // Nothing showing yet (first activation, restored chats): show the
        // newest tab. Only the selected workspace's chat gets its agent
        // started; a background workspace's waits until it's shown.
        if ws.activeTab == nil, let last = ws.tabOrder.last {
            if selectedWorkspaceId == id {
                selectTab(last, in: id)
            } else {
                ws.activeTab = last
            }
        }
    }

    @discardableResult
    private func ensureSession(_ info: TerminalInfo, in ws: WorkspaceState) -> PTYSession {
        if let existing = ws.sessions.first(where: { $0.id == info.id }) {
            existing.apply(info)
            return existing
        }
        let session = PTYSession(info: info, connection: connection)
        ws.sessions.append(session)
        let tab = TabRef.session(info.id)
        ws.insertTab(tab, replacing: pendingPlacements.removeValue(forKey: tab))
        session.attach()
        return session
    }

    @discardableResult
    private func ensureChat(_ summary: ChatSummary, in ws: WorkspaceState) -> ChatSession {
        if let existing = ws.chats.first(where: { $0.id == summary.id }) {
            existing.applySummary(summary)
            return existing
        }
        let cwd = workspaceById(ws.id)?.worktreePath ?? ""
        let chat = ChatSession(summary: summary, workspaceId: ws.id, cwd: cwd, backend: connection, files: EngineFiles.shared)
        ws.chats.append(chat)
        let tab = TabRef.chat(summary.id)
        ws.insertTab(tab, replacing: pendingPlacements.removeValue(forKey: tab))
        chat.subscribe()
        return chat
    }

    private func dropSession(_ session: PTYSession, from ws: WorkspaceState) {
        ws.sessions.removeAll { $0 === session }
        session.detach()
        // Detach from the incubator (or whichever container hosts it) so the
        // libghostty allocations don't outlive the tab.
        session.emulator.nsView.removeFromSuperview()
        if let next = ws.removeTab(.session(session.id)) {
            selectTab(next, in: ws.id)
        }
    }

    private func dropChat(_ chat: ChatSession, from ws: WorkspaceState) {
        ws.chats.removeAll { $0 === chat }
        chat.unsubscribe()
        if let next = ws.removeTab(.chat(chat.id)) {
            selectTab(next, in: ws.id)
        }
    }

    // MARK: - Repositories

    /// Adds a repository and returns it so the caller can chain UI (e.g. open
    /// the settings sheet). Returns `nil` if the picker was dismissed or the
    /// engine refused the path.
    @discardableResult
    func addRepository() async -> Repository? {
        guard let path = await pickRepositoryPath() else { return nil }
        do {
            let repo = try await connection.call(API.AddRepository(path: path))
            if !repositories.contains(where: { $0.id == repo.id }) {
                repositories.insert(repo, at: 0)
                workspacesByRepo[repo.id] = workspacesByRepo[repo.id] ?? []
            }
            return repo
        } catch {
            await presentError(error.localizedDescription)
            return nil
        }
    }

    func removeRepository(_ id: String) {
        if let repo = repositories.first(where: { $0.id == id }) {
            dropLocal(repositoryBaseWorkspaceId(for: repo))
        }
        for ws in workspacesByRepo[id] ?? [] { dropLocal(ws.id) }
        repositories.removeAll { $0.id == id }
        workspacesByRepo.removeValue(forKey: id)
        if selectedWorkspaceId.flatMap({ workspaceById($0) }) == nil {
            clearSelectedWorkspace()
        }
        perform(API.RemoveRepository(repoId: id))
    }

    func updateRepository(_ repo: Repository) {
        if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
            repositories[idx] = repo
        }
        perform(API.UpdateRepository(repository: repo))
    }

    /// Handler for `ForEach.onMove` (SwiftUI's "insert before this index"
    /// convention, which `Array.move` shares).
    func moveRepositorySections(from offsets: IndexSet, to destination: Int) {
        repositories.move(fromOffsets: offsets, toOffset: destination)
        perform(API.ReorderRepositories(orderedIds: repositories.map(\.id)))
    }

    /// Same convention, scoped to one repo's workspace rows.
    func moveWorkspaces(in repoId: String, from offsets: IndexSet, to destination: Int) {
        guard var list = workspacesByRepo[repoId],
              offsets.allSatisfy({ list.indices.contains($0) }),
              (0...list.count).contains(destination) else { return }
        list.move(fromOffsets: offsets, toOffset: destination)
        workspacesByRepo[repoId] = list
        perform(API.ReorderWorkspaces(repoId: repoId, orderedIds: list.map(\.id)))
    }

    /// Git refs for the repo settings sheet.
    func repoRefs(_ repo: Repository) async -> API.RepoRefsResult? {
        try? await connection.call(API.RepoRefs(repoId: repo.id))
    }

    func remoteBranches(_ repo: Repository) async -> [API.RemoteBranch] {
        (try? await connection.call(API.RemoteBranches(repoId: repo.id))) ?? []
    }

    func openPullRequests(_ repo: Repository) async throws -> API.OpenPullRequestsResult {
        try await connection.call(API.OpenPullRequests(repoId: repo.id))
    }

    // MARK: - Workspaces

    func repositoryBaseWorkspaceId(for repo: Repository) -> String {
        Self.repositoryBaseWorkspacePrefix + repo.id
    }

    func isRepositoryBaseWorkspace(_ workspace: Workspace) -> Bool {
        workspace.id.hasPrefix(Self.repositoryBaseWorkspacePrefix)
    }

    func selectRepositoryHead(_ repo: Repository) {
        selectWorkspace(repositoryBaseWorkspaceId(for: repo))
    }

    var selectedRepository: Repository? {
        guard let id = selectedWorkspaceId,
              let workspace = workspaceById(id) else { return nil }
        return repositories.first { $0.id == workspace.repositoryId }
    }

    func openWorkspaceCreationForSelectedRepository() {
        guard let repo = selectedRepository else { return }
        repoPendingWorkspaceCreation = repo
    }

    private func repositoryBaseWorkspace(for repo: Repository) -> Workspace {
        let touchedAt = repo.lastOpenedAt ?? repo.createdAt
        return Workspace(
            id: repositoryBaseWorkspaceId(for: repo),
            repositoryId: repo.id,
            name: repo.name,
            branchName: repo.defaultBranch,
            baseBranch: repo.defaultBranch,
            worktreePath: repo.path,
            agent: settings.defaultAgent,
            createdAt: repo.createdAt,
            lastActiveAt: touchedAt
        )
    }

    func createWorkspace(in repo: Repository, name: String) async {
        let connection = self.connection
        await create(in: repo) { override in
            try await connection.call(API.CreateWorkspace(repoId: repo.id, name: name, overrideExisting: override))
        }
    }

    /// Spin up a workspace against an existing PR's head branch.
    func createWorkspaceFromPR(in repo: Repository, pr: PRSummary, name: String) async {
        let connection = self.connection
        await create(in: repo) { override in
            try await connection.call(API.ImportBranch(repoId: repo.id, remoteRef: nil, pullRequest: pr, name: name, overrideExisting: override))
        }
    }

    /// Spin up a workspace against an existing remote branch (`origin/x`).
    func createWorkspaceFromBranch(in repo: Repository, remoteRef: String, name: String) async {
        let connection = self.connection
        await create(in: repo) { override in
            try await connection.call(API.ImportBranch(repoId: repo.id, remoteRef: remoteRef, pullRequest: nil, name: name, overrideExisting: override))
        }
    }

    /// Run a create request, asking before overriding a worktree that holds
    /// the branch, then select the new workspace (and show its setup output).
    private func create(in repo: Repository, _ request: (Bool) async throws -> API.CreateWorkspaceResult) async {
        do {
            var result = try await request(false)
            if case let .branchInUse(branch, path, dirty) = result {
                guard confirmWorktreeOverride(branchName: branch, worktreePath: path, hasUncommittedChanges: dirty) else { return }
                result = try await request(true)
            }
            guard case let .created(ws) = result else { return }
            if workspacesByRepo[repo.id]?.contains(where: { $0.id == ws.id }) != true {
                workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
            }
            selectWorkspace(ws.id)
            if repo.trimmedSetupScript != nil {
                inspectorTab = .run
                inspectorVisible = true
            }
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    private func confirmWorktreeOverride(branchName: String, worktreePath: String, hasUncommittedChanges: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Override existing worktree?"
        let dirtyWarning = hasUncommittedChanges
            ? "\n\nThis worktree has uncommitted changes. Overriding will permanently discard them."
            : ""
        alert.informativeText = """
        Branch \(branchName) is already checked out at:

        \(worktreePath)

        Overriding will force-remove that local worktree and delete the local branch before creating this workspace.\(dirtyWarning)
        """
        alert.alertStyle = hasUncommittedChanges ? .critical : .warning
        alert.addButton(withTitle: "Override and Delete Worktree")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func setupController(for workspaceId: String) -> SetupController? {
        workspaceState(for: workspaceId).setupController
    }

    /// Remove the worktree and its branch, the workspace's chats and its row.
    func deleteWorkspace(_ workspace: Workspace) async {
        reassignSelection(afterClosing: workspace.id)
        dropLocal(workspace.id)
        workspacesByRepo[workspace.repositoryId]?.removeAll { $0.id == workspace.id }
        do {
            _ = try await connection.call(API.DeleteWorkspace(workspaceId: workspace.id))
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    func selectWorkspace(_ id: String) {
        selectionHistory.removeAll { $0 == id }
        selectionHistory.append(id)
        selectedWorkspaceId = id
        connection.send(API.SetFocus(workspaceId: id))
        scheduleInspectorWorkspace(id)
        scheduleWorkspaceActivation(id)
    }

    /// Where selection should land after `id` closes: the most recently
    /// selected workspace that is still open, else the nearest open sidebar
    /// row above the closed one (below when nothing is open above).
    private func nextSelection(afterClosing id: String) -> String? {
        let openOrder = loadedSidebarWorkspaceOrder().filter { $0 != id }
        guard !openOrder.isEmpty else { return nil }
        let open = Set(openOrder)
        if let recent = selectionHistory.reversed().first(where: { $0 != id && open.contains($0) }) {
            return recent
        }
        let order = sidebarWorkspaceOrder()
        if let idx = order.firstIndex(of: id) {
            if let above = order[..<idx].last(where: { open.contains($0) }) { return above }
            if let below = order[idx...].first(where: { open.contains($0) }) { return below }
        }
        return openOrder.first
    }

    private func reassignSelection(afterClosing id: String) {
        guard selectedWorkspaceId == id else { return }
        if let next = nextSelection(afterClosing: id) {
            selectWorkspace(next)
        } else {
            clearSelectedWorkspace()
        }
    }

    private func clearSelectedWorkspace() {
        selectedWorkspaceId = nil
        workspaceActivationTask?.cancel()
        inspectorSelectionTask?.cancel()
        inspectorWorkspaceId = nil
        connection.send(API.SetFocus(workspaceId: nil))
    }

    private func scheduleWorkspaceActivation(_ id: String) {
        workspaceActivationTask?.cancel()
        workspaceActivationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let self, self.selectedWorkspaceId == id else { return }
            self.activateSelectedWorkspace(id)
        }
    }

    /// Ask the engine to bring the workspace up (restoring its chats, or a
    /// first tab). Its tabs arrive with the next status.
    private func activateSelectedWorkspace(_ id: String) {
        guard workspaceById(id) != nil, connection.isConnected else { return }
        // Tabs closed with the workspace come back on activation (restored
        // chats keep their ids); stop suppressing them.
        closingTabs = closingTabs.filter { $0.value != id }
        Task { [weak self] in
            guard let self else { return }
            do {
                if case .missing = try await self.connection.call(API.ActivateWorkspace(workspaceId: id, terminalSize: nil)) {
                    self.reassignSelection(afterClosing: id)
                }
            } catch {
                if (error as? WireError)?.code != "disconnected" {
                    await self.presentError(error.localizedDescription)
                }
            }
        }
    }

    private func scheduleInspectorWorkspace(_ id: String) {
        guard inspectorWorkspaceId != id else { return }
        inspectorSelectionTask?.cancel()
        inspectorSelectionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled else { return }
            guard let self, self.selectedWorkspaceId == id, self.workspaceById(id) != nil else { return }
            self.inspectorWorkspaceId = id
        }
    }

    // MARK: - Sessions

    /// Open a new tab for `agent` in whichever interface the settings pick.
    func startNewSession(for workspace: Workspace, agent: Workspace.AgentKind) {
        if settings.opensChat(for: agent), let provider = AgentProviderKind(agent: agent) {
            startNewChat(for: workspace, provider: provider)
        } else {
            startNewTerminal(for: workspace, agent: agent)
        }
    }

    /// `replacing` is a new-tab page the terminal takes the place of.
    func startNewTerminal(for workspace: Workspace, agent: Workspace.AgentKind, replacing: TabRef? = nil) {
        let request = API.CreateTerminal(workspaceId: workspace.id, agent: agent)
        Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.connection.call(request)
                self.show(.terminal(info), in: workspace.id, replacing: replacing)
            } catch {
                await self.presentError(error.localizedDescription)
            }
        }
    }

    /// Put a tab the engine opened into the strip (in `replacing`'s place
    /// when given) and select it — whether its status got here first or not.
    private func show(_ opened: OpenedTab, in workspaceId: String, replacing: TabRef? = nil) {
        let ws = workspaceState(for: workspaceId)
        let tab: TabRef
        switch opened {
        case let .terminal(info): tab = .session(info.id)
        case let .chat(summary): tab = .chat(summary.id)
        }
        if let replacing {
            if ws.tabOrder.contains(tab) {
                // Already appended by a status: move it into the slot.
                if ws.tabOrder.contains(replacing) {
                    ws.tabOrder.removeAll { $0 == tab }
                    if let index = ws.tabOrder.firstIndex(of: replacing) { ws.tabOrder[index] = tab }
                }
            } else {
                pendingPlacements[tab] = replacing
            }
        }
        switch opened {
        case let .terminal(info): ensureSession(info, in: ws)
        case let .chat(summary): ensureChat(summary, in: ws)
        }
        selectTab(tab, in: workspaceId)
    }

    func selectSession(_ sessionId: String, in workspaceId: String) {
        workspaceState(for: workspaceId).activeTab = .session(sessionId)
    }

    // MARK: - Chats

    /// Open a native chat tab. `prompt` is sent as the first message;
    /// `replacing` is a new-tab page the chat takes the place of.
    func startNewChat(
        for workspace: Workspace, provider: AgentProviderKind, prompt: String? = nil, replacing: TabRef? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.connection.call(API.StartChat(workspaceId: workspace.id, provider: provider, prompt: prompt))
                self.show(.chat(summary), in: workspace.id, replacing: replacing)
            } catch {
                await self.presentError(error.localizedDescription)
            }
        }
    }

    /// Bring a closed chat back as a tab, in `replacing`'s place if given.
    func reopenChat(_ record: ChatThreadRecord, in workspace: Workspace, replacing: TabRef? = nil) {
        let ws = workspaceState(for: workspace.id)
        if ws.chats.contains(where: { $0.id == record.id }) {
            if let replacing { _ = ws.removeTab(replacing) }
            selectChat(record.id, in: workspace.id)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.connection.call(API.ReopenChat(workspaceId: workspace.id, threadId: record.id))
                self.show(.chat(summary), in: workspace.id, replacing: replacing)
            } catch {
                await self.presentError(error.localizedDescription)
            }
        }
    }

    /// Closed chats for the new-tab page.
    func closedChats(in workspace: Workspace, limit: Int) async -> [ChatThreadRecord] {
        (try? await connection.call(API.ClosedChats(workspaceId: workspace.id, limit: limit))) ?? []
    }

    func selectChat(_ chatId: String, in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        ws.activeTab = .chat(chatId)
        ws.activeChat?.connectIfNeeded()
    }

    /// Close a chat tab. Like closing a session, closing the last agent tab
    /// closes the workspace.
    func closeChat(_ chatId: String, in workspaceId: String) {
        guard requireConnection() else { return }
        let ws = workspaceState(for: workspaceId)
        guard let idx = ws.chats.firstIndex(where: { $0.id == chatId }) else { return }
        let chat = ws.chats.remove(at: idx)
        closingTabs[chatId] = workspaceId
        let next = ws.removeTab(.chat(chatId))
        chat.unsubscribe()
        perform(API.CloseChat(chatId: chatId))
        if !ws.hasAgentTabs {
            closeWorkspace(workspaceId)
        } else if let next {
            selectTab(next, in: workspaceId)
        }
    }

    /// Continue a chat in the agent's own TUI.
    func openChatInTerminal(_ chat: ChatSession) {
        let workspaceId = chat.workspaceId
        let chatId = chat.id
        Task { [weak self] in
            guard let self else { return }
            do {
                if let info = try await self.connection.call(API.OpenChatInTerminal(chatId: chatId, size: nil)) {
                    self.show(.terminal(info), in: workspaceId)
                }
            } catch {
                await self.presentError(error.localizedDescription)
            }
        }
    }

    /// Remember a chat's model and effort as the default for new chats.
    func rememberChatModel(_ model: String?, effort: String?, for provider: AgentProviderKind) {
        var s = settings
        switch provider {
        case .claude:
            s.claudeChatModel = model
            s.claudeChatEffort = effort
        case .codex:
            s.codexChatModel = model
            s.codexChatEffort = effort
        }
        saveSettings(s)
    }

    /// Remember a chat's permission mode as the default for new chats.
    func rememberChatRuntimeMode(_ mode: AgentRuntimeMode) {
        guard settings.chatRuntimeMode != mode else { return }
        var s = settings
        s.chatRuntimeMode = mode
        saveSettings(s)
    }

    /// App quitting. A local engine takes its agents and terminals with it;
    /// a remote one keeps them running for the next connection.
    func shutdownAgents() async {
        if let engine = connection.inProcessEngine {
            await engine.shutdown()
        }
    }

    // MARK: - Diff tabs

    /// Show `path`'s full diff in the main area, reusing the file's tab if
    /// it's already open.
    func openDiffTab(path: String, mode: DiffMode, in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        let tab = DiffTab(path: path, mode: mode)
        if let idx = ws.diffTabs.firstIndex(where: { $0.id == tab.id }) {
            if ws.diffTabs[idx] != tab { ws.diffTabs[idx] = tab }
        } else {
            ws.diffTabs.append(tab)
            ws.insertTab(.diff(tab.id))
        }
        ws.activeTab = .diff(tab.id)
    }

    func selectDiffTab(_ tabId: String, in workspaceId: String) {
        workspaceState(for: workspaceId).activeTab = .diff(tabId)
    }

    /// Close a diff tab. An active one hands over to its strip neighbour.
    func closeDiffTab(_ tabId: String, in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        guard let idx = ws.diffTabs.firstIndex(where: { $0.id == tabId }) else { return }
        ws.diffTabs.remove(at: idx)
        if let next = ws.removeTab(.diff(tabId)) {
            selectTab(next, in: workspaceId)
        }
    }

    /// The full-file diff for a diff tab.
    func fullFileDiff(workspaceId: String, path: String, status: FileDiff.Status, mode: DiffMode) async throws -> FileDiff? {
        try await connection.call(API.FullFileDiff(workspaceId: workspaceId, path: path, status: status, mode: mode))
    }

    // MARK: - New-tab pages

    func openLauncherTab(in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        let id = UUID().uuidString
        ws.insertTab(.launcher(id))
        selectLauncherTab(id, in: workspaceId)
    }

    func selectLauncherTab(_ id: String, in workspaceId: String) {
        workspaceState(for: workspaceId).activeTab = .launcher(id)
    }

    func closeLauncherTab(_ id: String, in workspaceId: String) {
        if let next = workspaceState(for: workspaceId).removeTab(.launcher(id)) {
            selectTab(next, in: workspaceId)
        }
    }

    // MARK: - Tab strip

    func selectTab(_ tab: TabRef, in workspaceId: String) {
        switch tab {
        case .session(let id): selectSession(id, in: workspaceId)
        case .diff(let id):    selectDiffTab(id, in: workspaceId)
        case .chat(let id):    selectChat(id, in: workspaceId)
        case .launcher(let id): selectLauncherTab(id, in: workspaceId)
        }
    }

    func closeTab(_ tab: TabRef, in workspaceId: String) {
        switch tab {
        case .session(let id): closeSession(id, in: workspaceId)
        case .diff(let id):    closeDiffTab(id, in: workspaceId)
        case .chat(let id):    closeChat(id, in: workspaceId)
        case .launcher(let id): closeLauncherTab(id, in: workspaceId)
        }
    }

    // MARK: - Git actions

    /// A fresh tab with the configured agent and the rendered prompt as its
    /// first message.
    func startGitActionSession(for workspace: Workspace, action: GitAction) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let tab = try await self.connection.call(API.StartGitAction(workspaceId: workspace.id, action: action, terminalSize: nil))
                self.show(tab, in: workspace.id)
            } catch {
                await self.presentError(error.localizedDescription)
            }
        }
    }

    /// `gh pr merge` with the picked strategy (no agent involved).
    func performMerge(for workspace: Workspace, method: MergeMethod) async {
        do {
            _ = try await connection.call(API.Merge(workspaceId: workspace.id, method: method))
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    /// Queue an auto-merge: GitHub lands the PR once every protection rule
    /// is satisfied.
    func enableAutoMerge(for workspace: Workspace, method: MergeMethod) async {
        do {
            _ = try await connection.call(API.SetAutoMerge(workspaceId: workspace.id, enabled: true, method: method))
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    func disableAutoMerge(for workspace: Workspace) async {
        do {
            _ = try await connection.call(API.SetAutoMerge(workspaceId: workspace.id, enabled: false, method: nil))
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    /// Fast-path rebase; an agent tab opens if it can't finish cleanly.
    func performRebase(for workspace: Workspace) async {
        await fastPath(.rebaseOnMain, workspace)
    }

    /// Fast-path pull; an agent tab opens if it can't finish cleanly.
    func performPull(for workspace: Workspace) async {
        await fastPath(.pullUpdates, workspace)
    }

    private func fastPath(_ action: GitAction, _ workspace: Workspace) async {
        do {
            if let tab = try await connection.call(API.FastPathGitAction(workspaceId: workspace.id, action: action, terminalSize: nil)) {
                show(tab, in: workspace.id)
            }
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    /// Merge methods this workspace's repo allows, in GitHub's display
    /// order. Falls back to all three before the repo metadata loads.
    func allowedMergeMethods(for workspace: Workspace) -> [MergeMethod] {
        let allowed = repoMetadataByRepo[workspace.repositoryId]?.allowedMergeMethods
            ?? Set(MergeMethod.allCases)
        return MergeMethod.displayOrder.filter { allowed.contains($0) }
    }

    func allowsAutoMerge(for workspace: Workspace) -> Bool {
        repoMetadataByRepo[workspace.repositoryId]?.allowsAutoMerge ?? false
    }

    func defaultMergeMethod(for workspace: Workspace) -> MergeMethod? {
        let methods = allowedMergeMethods(for: workspace)
        if let last = lastMergeMethod(for: workspace), methods.contains(last) { return last }
        return methods.first
    }

    func lastMergeMethod(for workspace: Workspace) -> MergeMethod? {
        repositories
            .first(where: { $0.id == workspace.repositoryId })?
            .lastMergeMethod
            .flatMap(MergeMethod.init(rawValue:))
    }

    /// Drives the quit-confirmation dialog. Only a local engine loses its
    /// runs when the app quits.
    var hasOpenTabs: Bool {
        connection.inProcessEngine?.allWorkspaceStates.contains { $0.hasAgentTabs } ?? false
    }

    /// Close one session tab, handing the strip over to its neighbour when it
    /// was showing. Closing the last session closes the workspace.
    func closeSession(_ sessionId: String, in workspaceId: String) {
        guard requireConnection() else { return }
        let ws = workspaceState(for: workspaceId)
        guard let idx = ws.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = ws.sessions.remove(at: idx)
        closingTabs[sessionId] = workspaceId
        let next = ws.removeTab(.session(sessionId))
        session.terminate()
        session.emulator.nsView.removeFromSuperview()
        if !ws.hasAgentTabs {
            closeWorkspace(workspaceId)
        } else if let next {
            selectTab(next, in: workspaceId)
        }
    }

    /// Adopt a whole new strip order — what the native tab bar reports after
    /// a drag-reorder.
    func setTabOrder(_ order: [TabRef], in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        guard order != ws.tabOrder,
              order.count == ws.tabOrder.count,
              Set(order) == Set(ws.tabOrder) else { return }
        ws.tabOrder = order
    }

    /// Activate the Nth tab (1-indexed) of the active workspace.
    func selectTabByIndex(_ oneBased: Int) {
        guard let wsId = selectedWorkspaceId else { return }
        let tabs = workspaceState(for: wsId).tabOrder
        guard oneBased >= 1, oneBased <= tabs.count else { return }
        selectTab(tabs[oneBased - 1], in: wsId)
    }

    // MARK: - Run script

    /// Start or stop the run script (exclusive runs are handled engine-side).
    func toggleRun(for workspace: Workspace) {
        perform(API.ToggleRun(workspaceId: workspace.id))
    }

    func runController(for workspaceId: String) -> RunController? {
        workspaceState(for: workspaceId).runController
    }

    func isRunActive(_ workspaceId: String) -> Bool {
        workspaceState(for: workspaceId).runController?.isRunning ?? false
    }

    func hasRunHistory(_ workspaceId: String) -> Bool {
        workspaceState(for: workspaceId).runController != nil
    }

    func hasRunScript(_ workspace: Workspace) -> Bool {
        repositories.first { $0.id == workspace.repositoryId }?.trimmedRunScript != nil
    }

    func cycleTab(forward: Bool) {
        guard let wsId = selectedWorkspaceId else { return }
        let ws = workspaceState(for: wsId)
        let tabs = ws.tabOrder
        guard let active = ws.activeTab,
              let idx = tabs.firstIndex(of: active) else { return }
        let next = (idx + (forward ? 1 : -1) + tabs.count) % tabs.count
        selectTab(tabs[next], in: wsId)
    }

    /// Move through already-open workspaces as a vertical axis.
    func cycleWorkspaceSelection(forward: Bool) {
        let ids = loadedSidebarWorkspaceOrder()
        guard !ids.isEmpty else { return }
        let current = selectedWorkspaceId.flatMap { ids.firstIndex(of: $0) }
        let start = forward ? -1 : 0
        let idx = current ?? start
        let next = (idx + (forward ? 1 : -1) + ids.count) % ids.count
        selectWorkspace(ids[next])
    }

    private func loadedSidebarWorkspaceOrder() -> [String] {
        sidebarWorkspaceOrder().filter { id in
            guard let state = workspaceStates[id] else { return false }
            return state.hasAgentTabs
        }
    }

    private func sidebarWorkspaceOrder() -> [String] {
        repositories.flatMap { repo in
            [repositoryBaseWorkspaceId(for: repo)] + (workspacesByRepo[repo.id] ?? []).map(\.id)
        }
    }

    // MARK: - Diff & PR

    func refreshDiff(for workspace: Workspace) async {
        _ = try? await connection.call(API.RefreshDiff(workspaceId: workspace.id))
    }

    /// Kept for views that resolve repo metadata themselves; the engine
    /// broadcasts the same thing.
    func applyRepoMetadata(_ metadata: RepoIdentifier, for repoId: String) {
        if repoMetadataByRepo[repoId] != metadata {
            repoMetadataByRepo[repoId] = metadata
        }
    }

    /// User-initiated refresh (drives the inspector spinner).
    func requestPRRefresh(workspaceId: String) {
        workspaceState(for: workspaceId).isRefreshingPR = true
        perform(API.RefreshPR(workspaceId: workspaceId))
    }

    /// Close a workspace's live runtime — sessions, chats, run/setup —
    /// while keeping its sidebar entry and cached diff/PR state.
    func closeWorkspace(_ id: String) {
        guard requireConnection() else { return }
        if let ws = workspaceStates[id] {
            tearDownLocalRuntime(ws)
        }
        perform(API.CloseWorkspace(workspaceId: id))
        reassignSelection(afterClosing: id)
        selectionHistory.removeAll { $0 == id }
    }

    /// Drop a workspace's local state (it's going away engine-side).
    private func dropLocal(_ id: String) {
        if let ws = workspaceStates.removeValue(forKey: id) {
            tearDownLocalRuntime(ws)
        }
        selectionHistory.removeAll { $0 == id }
    }

    private func tearDownLocalRuntime(_ ws: WorkspaceState) {
        for session in ws.sessions {
            closingTabs[session.id] = ws.id
            session.detach()
            session.emulator.nsView.removeFromSuperview()
        }
        ws.sessions.removeAll()
        for chat in ws.chats {
            closingTabs[chat.id] = ws.id
            chat.unsubscribe()
        }
        ws.chats.removeAll()
        ws.diffTabs.removeAll()
        ws.activeTab = nil
        ws.tabOrder.removeAll()
        ws.setupController?.discard()
        ws.setupController = nil
        ws.runController?.discard()
        ws.runController = nil
    }

    // MARK: - Helpers

    func workspaceById(_ id: String) -> Workspace? {
        for list in workspacesByRepo.values {
            if let ws = list.first(where: { $0.id == id }) { return ws }
        }
        if id.hasPrefix(Self.repositoryBaseWorkspacePrefix) {
            let repoId = String(id.dropFirst(Self.repositoryBaseWorkspacePrefix.count))
            if let repo = repositories.first(where: { $0.id == repoId }) {
                return repositoryBaseWorkspace(for: repo)
            }
        }
        return nil
    }

    func saveSettings(_ s: AppSettings) {
        let old = settings
        settings = s
        if old.monospaceFontFamily != s.monospaceFontFamily || old.terminalFontSize != s.terminalFontSize {
            applyTerminalFont(s)
        }
        pendingSettingsSaves += 1
        Task { [weak self] in
            do {
                _ = try await self?.connection.call(API.SaveSettings(settings: s))
            } catch {
                if (error as? WireError)?.code != "disconnected" {
                    await self?.presentError(error.localizedDescription)
                }
            }
            self?.pendingSettingsSaves -= 1
        }
    }

    private var pendingSettingsSaves = 0

    /// Push terminal font settings to every live session so changes land
    /// immediately. (Inner horizontal padding is applied at the view layer —
    /// see `TerminalHostView`.)
    private func applyTerminalFont(_ s: AppSettings) {
        for ws in workspaceStates.values {
            for session in ws.sessions {
                session.emulator.updateFont(
                    family: MonoFont.terminalFamily(s.monospaceFontFamily),
                    size: s.terminalFontSize
                )
            }
        }
    }

    /// Actions that change engine state wait for the link: done locally
    /// and dropped on the way, they'd leave the mirror lying.
    private func requireConnection() -> Bool {
        guard !connection.isConnected else { return true }
        NSSound.beep()
        return false
    }

    /// Fire a request whose only interesting outcome is failure.
    private func perform<R: RPC>(_ request: R) {
        Task { [weak self] in
            do {
                _ = try await self?.connection.call(request)
            } catch {
                if (error as? WireError)?.code != "disconnected" {
                    await self?.presentError(error.localizedDescription)
                }
            }
        }
    }

    /// A repository to add: a folder picker for a local engine; for a
    /// remote one, a path on that machine.
    private func pickRepositoryPath() async -> String? {
        if connection.isLocal {
            return await pickDirectory()
        }
        return await RemoteFolderPicker.pick(connection: connection)
    }

    private func pickDirectory() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = "Add repository"
                panel.prompt = "Add"
                panel.begin { resp in
                    if resp == .OK, let url = panel.url {
                        continuation.resume(returning: url.path)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    func presentError(_ message: String) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    #if DEBUG
    /// Development hooks for driving the app from a script:
    /// `-JetlineOpenWorkspace <id>` selects a workspace at launch (a repo's
    /// base checkout is `repo-base:<repo id>`), and `-JetlineSendPrompt
    /// <text>` sends a message to the chat that opens there
    /// (`-JetlinePlanMode YES` sends it in plan mode).
    private var appliedDebugArguments = false
    private func applyDebugLaunchArguments() {
        guard !appliedDebugArguments else { return }
        appliedDebugArguments = true
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: "JetlineOpenWorkspace"), workspaceById(id) != nil else { return }
        selectWorkspace(id)
        guard let prompt = defaults.string(forKey: "JetlineSendPrompt") else { return }
        let plan = defaults.bool(forKey: "JetlinePlanMode")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let chat = self?.workspaceState(for: id).activeChat else { return }
            if plan { chat.setInteractionMode(.plan) }
            chat.send(text: prompt)
        }
    }
    #endif
}
#endif
