import Foundation
import SwiftUI
import AppKit

/// Root observable state. Owns repositories, workspaces, sessions, selection.
///
/// Per-workspace mutable state (diff snapshots, PR snapshots, sessions,
/// run/setup controllers, etc.) lives in `WorkspaceState` instances looked
/// up via `workspaceState(for:)`, *not* in `@Published` dicts on this
/// object. That split keeps a single workspace's poll/diff update from
/// invalidating every view in the app via the shared `@Published` surface.
@MainActor
final class AppState: ObservableObject {
    @Published var repositories: [Repository] = []
    @Published var workspacesByRepo: [String: [Workspace]] = [:]
    @Published var selectedWorkspaceId: String?
    @Published var settings: AppSettings = AppSettings()
    /// Per-repo GitHub metadata (owner/name + allowed merge methods),
    /// resolved on the first PR poll and reused for the app's lifetime.
    /// Drives the merge confirmation dialog's button set.
    @Published var repoMetadataByRepo: [String: RepoIdentifier] = [:]
    @Published var prTrackerStatus: PRTracker.Status = .ok
    @Published var inspectorVisible: Bool = true
    /// Active inspector tab. Lifted out of `InspectorView` so workspace
    /// creation can flip it to `.run` and surface live setup-script output.
    @Published var inspectorTab: InspectorTab = .changes

    /// Per-workspace mutable state. Not `@Published` — views look up the
    /// `WorkspaceState` for their workspace and observe it via
    /// `@ObservedObject`, so a single workspace's mutations only invalidate
    /// the views that actually read them.
    private var workspaceStates: [String: WorkspaceState] = [:]

    private var watchers: [String: WorktreeWatcher] = [:]
    private(set) lazy var prTracker: PRTracker = PRTracker(state: self)
    private var hasLoaded = false

    init() {}

    /// Get-or-create the `WorkspaceState` for `id`. Lazy so callers don't
    /// need to seed entries before mutating; orphan states from
    /// transiently-missing workspaces get cleared in `detachWorkspace`.
    func workspaceState(for id: String) -> WorkspaceState {
        if let existing = workspaceStates[id] { return existing }
        let new = WorkspaceState(id: id)
        workspaceStates[id] = new
        return new
    }

    // MARK: - Load

    /// Idempotent. Driven by `AppShell`'s `.task` so SwiftUI owns the
    /// lifecycle (instead of an init-time `Task { ... }` that escapes the
    /// SwiftUI graph and runs even when nothing observes the state).
    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            settings = try SettingsStore.load()
            let repos = try Repositories.all()
            repositories = repos
            for r in repos {
                workspacesByRepo[r.id] = (try? Workspaces.forRepository(r.id)) ?? []
            }
            // Hydrate PR snapshots from disk so the sidebar paints
            // stale-but-known state immediately. The tracker overwrites these
            // entries as fresh data lands.
            if let cached = try? PRSnapshots.loadAll() {
                for (wsId, snap) in cached {
                    workspaceState(for: wsId).pr = snap
                }
            }
        } catch {
            print("AppState load error: \(error)")
        }
        prTracker.sync()
    }

    // MARK: - Repositories

    /// Adds a repository and returns it so the caller can chain UI (e.g. open
    /// the settings sheet so the user configures scripts before the first
    /// workspace is spawned). Returns `nil` if the picker was dismissed or
    /// the path failed validation.
    @discardableResult
    func addRepository() async -> Repository? {
        guard let path = await pickDirectory() else { return nil }
        guard await WorktreeOps.isGitRepo(at: path) else {
            await presentError("Not a git repository: \(path)")
            return nil
        }
        do {
            let defaultBranch = (try? await WorktreeOps.defaultBranch(at: path)) ?? "main"
            let name = WorktreeOps.detectName(at: path)
            let repo = try Repositories.add(name: name, path: path, defaultBranch: defaultBranch)
            repositories.insert(repo, at: 0)
            workspacesByRepo[repo.id] = []
            prTracker.sync()
            return repo
        } catch {
            await presentError(error.localizedDescription)
            return nil
        }
    }

    func removeRepository(_ id: String) {
        if let workspaces = workspacesByRepo[id] {
            for ws in workspaces { detachWorkspace(ws.id) }
        }
        try? Repositories.remove(id: id)
        repositories.removeAll { $0.id == id }
        workspacesByRepo.removeValue(forKey: id)
        repoMetadataByRepo.removeValue(forKey: id)
        if selectedWorkspaceId.flatMap({ workspaceById($0) }) == nil {
            selectedWorkspaceId = nil
        }
        prTracker.sync()
    }

    func updateRepository(_ repo: Repository) {
        do {
            try Repositories.update(repo)
            if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
                repositories[idx] = repo
            }
        } catch {
            Task { await presentError(error.localizedDescription) }
        }
    }

    // MARK: - Workspaces

    func createWorkspace(in repo: Repository, name: String) async {
        let id = UUID().uuidString
        let slug = WorktreeOps.slug(name)
        let prefix = await effectiveBranchPrefix(for: repo)
        let branch = "\(prefix)\(slug)-\(id.prefix(6))"
        let agent = settings.defaultAgent

        do {
            let path = try await WorktreeOps.create(
                repoPath: repo.path,
                worktreeId: id,
                repoId: repo.id,
                branchName: branch,
                baseBranch: repo.defaultBranch
            )
            let now = Date()
            let ws = Workspace(
                id: id,
                repositoryId: repo.id,
                name: name,
                branchName: branch,
                baseBranch: repo.defaultBranch,
                worktreePath: path,
                agent: agent,
                createdAt: now,
                lastActiveAt: now
            )
            try Workspaces.insert(ws)
            workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
            // Seed the PR snapshot to `.absent` — a freshly minted local
            // branch can't have a PR yet, and without this seed the row is
            // iconless and the inspector reads "Loading PR…" until the
            // next GitHub poll lands (up to ~60s away).
            applyPR(.absent, for: ws.id)
            prTracker.kick(repoId: repo.id)
            selectWorkspace(ws.id)
            startSetupIfNeeded(workspace: ws, repository: repo)
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    /// Spin up a workspace against an existing PR's head branch. Picker
    /// already filters forks; if a fork slips through, the underlying
    /// `git fetch` will fail with a clear message.
    func createWorkspaceFromPR(
        in repo: Repository,
        pr: PRSummary,
        name: String
    ) async {
        await importBranchAsWorkspace(
            in: repo,
            branchName: pr.headRefName,
            baseBranch: pr.baseRefName,
            name: name
        )
    }

    /// Spin up a workspace against an existing remote branch. `remoteRef` is
    /// what `git for-each-ref` emits — e.g. `origin/feature`. The remote
    /// prefix is stripped to derive the local branch name.
    func createWorkspaceFromBranch(
        in repo: Repository,
        remoteRef: String,
        name: String
    ) async {
        await importBranchAsWorkspace(
            in: repo,
            branchName: repo.localName(forRemoteRef: remoteRef),
            baseBranch: repo.defaultBranch,
            name: name
        )
    }

    /// Shared body for the two import entry points. Branch identity is
    /// preserved verbatim — none of `effectiveBranchPrefix` / slug / id-suffix
    /// applies here.
    private func importBranchAsWorkspace(
        in repo: Repository,
        branchName: String,
        baseBranch: String,
        name: String
    ) async {
        let id = UUID().uuidString
        let agent = settings.defaultAgent
        let path: String
        do {
            path = try await WorktreeOps.importExisting(
                repoPath: repo.path,
                worktreeId: id,
                repoId: repo.id,
                branchName: branchName,
                remote: repo.remoteOrigin
            )
        } catch {
            await presentError(error.localizedDescription)
            return
        }

        let now = Date()
        let ws = Workspace(
            id: id,
            repositoryId: repo.id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            worktreePath: path,
            agent: agent,
            createdAt: now,
            lastActiveAt: now
        )
        do {
            try Workspaces.insert(ws)
        } catch {
            // Worktree was created; the DB insert is the only thing that
            // failed. Tear the worktree down again so we don't leak it.
            // Pass `branchName: nil` — the local branch is the user's, not
            // ours, and they may want it for a retry.
            try? await WorktreeOps.remove(
                repoPath: repo.path,
                worktreePath: path,
                branchName: nil,
                force: true
            )
            await presentError(error.localizedDescription)
            return
        }
        workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
        prTracker.kick(repoId: repo.id)
        selectWorkspace(ws.id)
        startSetupIfNeeded(workspace: ws, repository: repo)
    }

    /// Spawn the repo's setup script for `workspace` and route its output
    /// into the inspector's run panel. No-ops for blank scripts. The
    /// inspector flips to `.run` so the user lands on live output instead of
    /// the diff (which is empty for a brand-new worktree anyway).
    private func startSetupIfNeeded(workspace: Workspace, repository: Repository) {
        guard let script = repository.trimmedSetupScript else { return }
        let controller = SetupController(workspaceId: workspace.id)
        workspaceState(for: workspace.id).setupController = controller
        controller.start(
            script: script,
            cwd: workspace.worktreePath,
            env: ScriptRunner.defaultEnv(repoPath: repository.path)
        )
        inspectorTab = .run
        inspectorVisible = true
    }

    func setupController(for workspaceId: String) -> SetupController? {
        workspaceState(for: workspaceId).setupController
    }

    func archiveWorkspace(_ workspace: Workspace, removeWorktree: Bool) async {
        // Stop the run script first; otherwise it keeps writing to a deleted dir.
        let ws = workspaceState(for: workspace.id)
        ws.runController?.discard()
        ws.runController = nil
        detachWorkspace(workspace.id)

        let repo = repositories.first(where: { $0.id == workspace.repositoryId })
        if removeWorktree, let repo {
            if let archive = repo.trimmedArchiveScript {
                _ = await ScriptRunner.run(
                    archive,
                    cwd: workspace.worktreePath,
                    env: ScriptRunner.defaultEnv(repoPath: repo.path)
                )
            }
            try? await WorktreeOps.remove(
                repoPath: repo.path,
                worktreePath: workspace.worktreePath,
                branchName: workspace.branchName,
                force: true
            )
        }
        try? Workspaces.archive(id: workspace.id)
        try? PRSnapshots.remove(workspaceId: workspace.id)
        workspacesByRepo[workspace.repositoryId]?.removeAll { $0.id == workspace.id }
        if selectedWorkspaceId == workspace.id { selectedWorkspaceId = nil }
    }

    /// Compute the prefix prepended to a fresh workspace's branch name.
    ///
    /// The `branchPrefixMode` field is the source of truth when set:
    /// `.username` derives from `git config user.name`, `.custom` uses the
    /// stored `branchPrefix`, `.none` produces an empty string. Repos
    /// migrated from before the mode field have nil mode, in which case we
    /// honour the legacy fallback chain (custom value → global → built-in).
    private func effectiveBranchPrefix(for repo: Repository) async -> String {
        if let raw = repo.branchPrefixMode, let mode = BranchPrefixMode(rawValue: raw) {
            switch mode {
            case .username:
                let slug = await WorktreeOps.usernameSlug(at: repo.path)
                return slug.isEmpty ? "" : slug + "/"
            case .custom:
                return repo.branchPrefix?.nonBlank ?? ""
            case .none:
                return ""
            }
        }
        return repo.branchPrefix?.nonBlank
            ?? settings.globalBranchPrefix.nonBlank
            ?? "jetline/"
    }

    func selectWorkspace(_ id: String) {
        selectedWorkspaceId = id
        try? Workspaces.touch(id: id)

        guard let ws = workspaceById(id) else { return }
        ensureSessionExists(for: ws)
        startWatcher(for: ws)
        Task { await refreshDiff(for: ws) }
    }

    // MARK: - Sessions

    /// Spawn a fresh tab the first time a workspace is selected this app run.
    private func ensureSessionExists(for workspace: Workspace) {
        guard workspaceState(for: workspace.id).sessions.isEmpty else { return }
        startNewSession(for: workspace, agent: workspace.agent)
    }

    func startNewSession(for workspace: Workspace, agent: Workspace.AgentKind) {
        let session = PTYSession(
            workspaceId: workspace.id,
            agent: agent,
            cwd: workspace.worktreePath
        )
        let ws = workspaceState(for: workspace.id)
        ws.sessions.append(session)
        ws.activeSessionId = session.id
        Task { await session.startIfNeeded() }
    }

    func selectSession(_ sessionId: String, in workspaceId: String) {
        workspaceState(for: workspaceId).activeSessionId = sessionId
    }

    // MARK: - Git actions

    /// Spawns a fresh tab with the user-selected agent and the rendered
    /// prompt as its first message. Merge has its own path (`performMerge`)
    /// because the caller picks a strategy from the confirmation dialog.
    func startGitActionSession(for workspace: Workspace, action: GitAction) {
        let agent = resolveAgent(for: action)
        let repo = repositories.first(where: { $0.id == workspace.repositoryId })
        guard let template = GitActionPrompts.template(
            for: action,
            repository: repo,
            settings: settings
        ) else { return }

        let pr: PullRequest?
        let checks: [CheckRun]
        if case let .loaded(pull, runs) = workspaceState(for: workspace.id).pr {
            pr = pull
            checks = runs
        } else {
            pr = nil
            checks = []
        }
        let prompt = GitActionPrompts.render(template, workspace: workspace, pr: pr, checks: checks)

        let session = PTYSession(
            workspaceId: workspace.id,
            agent: agent,
            cwd: workspace.worktreePath,
            initialPrompt: prompt
        )
        let ws = workspaceState(for: workspace.id)
        ws.sessions.append(session)
        ws.activeSessionId = session.id
        Task { await session.startIfNeeded() }
    }

    /// Resolve the agent for a given action through the fallback chain:
    /// review → reviewAgent → defaultAgent; everything else → gitAgent →
    /// defaultAgent. `.shell` is filtered out because it can't act on a
    /// prompt autonomously.
    private func resolveAgent(for action: GitAction) -> Workspace.AgentKind {
        let preferred: Workspace.AgentKind? =
            action.usesReviewAgent ? settings.reviewAgent : settings.gitAgent
        let chosen = preferred ?? settings.defaultAgent
        return chosen == .shell ? .claude : chosen
    }

    /// Run `gh pr merge` with the user-picked strategy (no agent involved).
    /// On success persists the method as the repo's `lastMergeMethod` so
    /// next time it becomes the dialog's default. Kicks the PR tracker so
    /// the sidebar reflects the merged state without waiting for the next
    /// scheduled poll.
    func performMerge(for workspace: Workspace, method: MergeMethod) async {
        let ws = workspaceState(for: workspace.id)
        guard case let .loaded(pr, _) = ws.pr else { return }
        ws.runningGitAction = .mergePR
        defer { ws.runningGitAction = nil }
        do {
            try await GitHubRunner.mergePR(pr.number, method: method, cwd: workspace.worktreePath)
        } catch {
            await presentError(error.localizedDescription)
            return
        }
        if var repo = repositories.first(where: { $0.id == workspace.repositoryId }),
           repo.lastMergeMethod != method.rawValue {
            repo.lastMergeMethod = method.rawValue
            updateRepository(repo)
        }
        prTracker.kick(workspaceId: workspace.id)
    }

    /// Fast path for `Rebase`. Tries `git fetch` + `git rebase --autostash`
    /// directly so the common no-conflict case completes without spending
    /// agent tokens; `--autostash` lets a dirty working tree go through
    /// untouched. Anything that goes wrong — conflicts, missing refs,
    /// fetch failure — aborts the partial rebase and hands off to the
    /// agent flow that already knows how to recover.
    func performRebase(for workspace: Workspace) async {
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }) else {
            startGitActionSession(for: workspace, action: .rebaseOnMain)
            return
        }
        let ws = workspaceState(for: workspace.id)
        ws.runningGitAction = .rebaseOnMain
        defer { ws.runningGitAction = nil }

        let cwd = workspace.worktreePath
        let baseRef = "\(repo.remoteOrigin)/\(repo.localName(forRemoteRef: workspace.baseBranch))"

        let fellBack: Bool
        do {
            await BranchPositionOps.fetch(repoPath: cwd, remote: repo.remoteOrigin)
            let result = try await GitRunner.run(["rebase", "--autostash", baseRef], cwd: cwd)
            fellBack = !result.success
        } catch {
            fellBack = true
        }

        if fellBack {
            _ = try? await GitRunner.run(["rebase", "--abort"], cwd: cwd)
            startGitActionSession(for: workspace, action: .rebaseOnMain)
            return
        }

        prTracker.kick(workspaceId: workspace.id)
        await refreshDiff(for: workspace)
    }

    /// Fast path for `Pull updates`. Mirrors `performRebase`: tries
    /// `git pull --rebase --autostash` directly and falls back to the agent
    /// flow on conflict / failure. Pull-rebase leaves a partial state in
    /// `.git/rebase-merge` on conflict; `git rebase --abort` clears it.
    func performPull(for workspace: Workspace) async {
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }) else {
            startGitActionSession(for: workspace, action: .pullUpdates)
            return
        }
        let ws = workspaceState(for: workspace.id)
        ws.runningGitAction = .pullUpdates
        defer { ws.runningGitAction = nil }

        let cwd = workspace.worktreePath

        let fellBack: Bool
        do {
            let result = try await GitRunner.run(
                ["pull", "--rebase", "--autostash", repo.remoteOrigin, workspace.branchName],
                cwd: cwd
            )
            fellBack = !result.success
        } catch {
            fellBack = true
        }

        if fellBack {
            _ = try? await GitRunner.run(["rebase", "--abort"], cwd: cwd)
            startGitActionSession(for: workspace, action: .pullUpdates)
            return
        }

        prTracker.kick(workspaceId: workspace.id)
        await refreshDiff(for: workspace)
    }

    /// Last merge method the user chose for this workspace's repo. `nil`
    /// when the user has never merged here.
    func lastMergeMethod(for workspace: Workspace) -> MergeMethod? {
        repositories
            .first(where: { $0.id == workspace.repositoryId })?
            .lastMergeMethod
            .flatMap(MergeMethod.init(rawValue:))
    }

    func activeSession(for workspaceId: String) -> PTYSession? {
        let ws = workspaceState(for: workspaceId)
        guard let id = ws.activeSessionId else { return nil }
        return ws.sessions.first { $0.id == id }
    }

    /// True iff at least one workspace currently has open tabs. Drives the
    /// quit-confirmation dialog so the user doesn't lose an in-flight agent
    /// run by reflex-quitting.
    var hasOpenTabs: Bool {
        workspaceStates.values.contains { !$0.sessions.isEmpty }
    }

    /// Close one tab. Picks a neighbour to activate; if it was the last tab,
    /// spawns a fresh one with the default agent so the workspace is never
    /// empty (the surface would otherwise show only a spinner).
    func closeSession(_ sessionId: String, in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        guard let idx = ws.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = ws.sessions.remove(at: idx)
        session.terminate()
        // Detach from the incubator (or whichever container hosts it) so
        // dropping the PTYSession actually releases the AppTerminalView —
        // otherwise the parked subview keeps a strong ref and the
        // libghostty allocations outlive the close.
        session.emulator.nsView.removeFromSuperview()

        if ws.activeSessionId == sessionId {
            let neighbour = idx < ws.sessions.count ? ws.sessions[idx] : ws.sessions.last
            ws.activeSessionId = neighbour?.id
        }

        if ws.sessions.isEmpty, let workspace = workspaceById(workspaceId) {
            startNewSession(for: workspace, agent: settings.defaultAgent)
        }
    }

    /// Move one session to a target final index. Used by the tab strip's
    /// drag reorder; the callsite computes the destination once on drag-end
    /// so we don't thrash observers mid-drag.
    func moveSession(_ sourceId: String, toIndex newIndex: Int, in workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        guard let from = ws.sessions.firstIndex(where: { $0.id == sourceId }),
              newIndex >= 0, newIndex < ws.sessions.count, from != newIndex else { return }
        let item = ws.sessions.remove(at: from)
        ws.sessions.insert(item, at: newIndex)
    }

    /// Activate the Nth tab (1-indexed) of the active workspace. Used by ⌘1…⌘9.
    func selectSessionByIndex(_ oneBased: Int) {
        guard let wsId = selectedWorkspaceId else { return }
        let sessions = workspaceState(for: wsId).sessions
        guard oneBased >= 1, oneBased <= sessions.count else { return }
        selectSession(sessions[oneBased - 1].id, in: wsId)
    }

    // MARK: - Run script

    /// Toggle the run script for a workspace. Honours the per-repo
    /// `runExclusive` flag — starting an exclusive run stops every other
    /// active runner in the same repository first.
    func toggleRun(for workspace: Workspace) {
        let ws = workspaceState(for: workspace.id)
        if let runner = ws.runController, runner.isRunning {
            runner.stop()
            return
        }
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }),
              let script = repo.trimmedRunScript else { return }

        if repo.runExclusive {
            let peerIds = Set(workspacesByRepo[repo.id]?.map(\.id) ?? [])
            for (otherId, peer) in workspaceStates
            where otherId != workspace.id && peerIds.contains(otherId) {
                if let runner = peer.runController, runner.isRunning {
                    runner.stop()
                }
            }
        }

        // Drop the setup transcript so that when the run eventually exits
        // the panel falls back to the placeholder, not to "Setup complete".
        if let setup = ws.setupController {
            setup.discard()
            ws.setupController = nil
        }

        let runner = ws.runController ?? RunController(workspaceId: workspace.id)
        ws.runController = runner
        runner.start(
            script: script,
            cwd: workspace.worktreePath,
            env: ScriptRunner.defaultEnv(repoPath: repo.path)
        )
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

    /// Cycle to the next or previous tab of the active workspace. Wraps.
    func cycleSession(forward: Bool) {
        guard let wsId = selectedWorkspaceId else { return }
        let ws = workspaceState(for: wsId)
        guard !ws.sessions.isEmpty,
              let activeId = ws.activeSessionId,
              let idx = ws.sessions.firstIndex(where: { $0.id == activeId }) else { return }
        let next = (idx + (forward ? 1 : -1) + ws.sessions.count) % ws.sessions.count
        selectSession(ws.sessions[next].id, in: wsId)
    }

    // MARK: - Diff & watcher

    func refreshDiff(for workspace: Workspace) async {
        // Resolve merge-base once and share with combined+pr. nil means the
        // lookup itself failed (offline base / brand-new repo); each mode's
        // compute then falls back to its own resolution and surfaces the
        // error there.
        let mergeBase = try? await DiffComputer.mergeBase(
            worktreePath: workspace.worktreePath,
            baseBranch: workspace.baseBranch
        )

        async let combined: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .combined,
                precomputedMergeBase: mergeBase
            )
        }()
        async let prSnap: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .pr,
                precomputedMergeBase: mergeBase
            )
        }()
        async let localSnap: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .local
            )
        }()
        async let uncommitted = DiffComputer.hasUncommittedChanges(
            worktreePath: workspace.worktreePath
        )

        let ws = workspaceState(for: workspace.id)
        if let snap = await combined, ws.diff != snap {
            ws.diff = snap
        }
        if let snap = await prSnap, ws.prDiff != snap {
            ws.prDiff = snap
        }
        if let snap = await localSnap, ws.localDiff != snap {
            ws.localDiff = snap
        }
        let dirty = await uncommitted
        if ws.hasUncommitted != dirty {
            ws.hasUncommitted = dirty
        }
    }

    /// Single write path for PR snapshots. `PRTracker` calls this with fresh
    /// data; the in-memory state drives the UI and the same value is mirrored
    /// to disk so the next launch can paint immediately. No-op writes are
    /// suppressed so we don't kick observers on every poll.
    func applyPR(_ snapshot: PRSnapshot, for workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        if ws.pr != snapshot {
            ws.pr = snapshot
        }
        try? PRSnapshots.save(snapshot, for: workspaceId)
    }

    /// User-initiated refresh: mark the workspace as awaiting a poll result
    /// (drives the spinner) and wake the tracker. The marker is cleared by
    /// `endPRRefresh` from `pollGitHub`'s defer; the timeout is a backstop
    /// in case the poll never reaches the defer (e.g. tracker was torn down).
    func requestPRRefresh(workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        if !ws.isRefreshingPR {
            ws.isRefreshingPR = true
        }
        prTracker.kick(workspaceId: workspaceId)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.endPRRefresh(workspaceId: workspaceId)
        }
    }

    func endPRRefresh(workspaceId: String) {
        // Guard so the per-poll defer doesn't notify observers for every
        // workspace whose marker was already cleared.
        let ws = workspaceState(for: workspaceId)
        if ws.isRefreshingPR {
            ws.isRefreshingPR = false
        }
    }

    /// Single write path for the repo metadata cache. PRTracker calls this
    /// when it first resolves a repo's owner/name + allowed merge methods.
    /// No-op writes are suppressed so Combine doesn't notify on every poll.
    func applyRepoMetadata(_ metadata: RepoIdentifier, for repoId: String) {
        if repoMetadataByRepo[repoId] != metadata {
            repoMetadataByRepo[repoId] = metadata
        }
    }

    /// Single write path for branch positions. No-op writes are suppressed
    /// so an unchanged ahead/behind state doesn't kick observers.
    func applyBranchPosition(_ position: BranchPosition, for workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        if ws.branchPosition != position {
            ws.branchPosition = position
        }
    }

    private func startWatcher(for workspace: Workspace) {
        guard watchers[workspace.id] == nil else { return }
        let id = workspace.id
        let worktreePath = workspace.worktreePath
        // Resolve the worktree's git-dir asynchronously so we can watch
        // both. Without watching the git-dir, `git commit` (which mutates
        // `<repo>/.git/worktrees/<id>/{HEAD,index}` outside the worktree
        // path) doesn't fire FSEvents and the diff snapshot stays stale.
        // selectWorkspace already kicks off a refreshDiff so the brief
        // window before the watcher arms is covered.
        Task { [weak self] in
            guard let self else { return }
            let gitDir = await WorktreeOps.gitDir(at: worktreePath)
            await MainActor.run {
                guard self.watchers[id] == nil,
                      self.workspaceById(id) != nil else { return }
                var additional: [String] = []
                if let gitDir, gitDir != worktreePath {
                    additional.append(gitDir)
                }
                let watcher = WorktreeWatcher(
                    worktreePath: worktreePath,
                    additionalPaths: additional
                ) { [weak self] in
                    guard let self else { return }
                    guard let ws = self.workspaceById(id) else { return }
                    Task { await self.refreshDiff(for: ws) }
                    // Worktree changed — likely a commit or push. Wake the
                    // PR tracker so the sidebar reflects new state without
                    // waiting up to a minute for the next scheduled poll.
                    self.prTracker.kick(workspaceId: id)
                }
                watcher.start()
                self.watchers[id] = watcher
            }
        }
    }

    private func detachWorkspace(_ id: String) {
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        if let ws = workspaceStates[id] {
            for s in ws.sessions {
                s.terminate()
                s.emulator.nsView.removeFromSuperview()
            }
            ws.setupController?.discard()
        }
        workspaceStates.removeValue(forKey: id)
    }

    // MARK: - Helpers

    func workspaceById(_ id: String) -> Workspace? {
        for list in workspacesByRepo.values {
            if let ws = list.first(where: { $0.id == id }) { return ws }
        }
        return nil
    }

    func saveSettings(_ s: AppSettings) {
        do {
            try SettingsStore.save(s)
            settings = s
        } catch {
            Task { await presentError(error.localizedDescription) }
        }
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

    private func presentError(_ message: String) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
