import Foundation

/// Stacking between workspaces is derived, not stored: a workspace sits on
/// top of another in the same repository when its base branch is that
/// workspace's branch. GitHub retargeting a PR (after the layer below it
/// merges) moves the base, and with it the stack, without any bookkeeping.
enum WorkspaceStacks {
    /// The workspace `workspace` is stacked on, if any.
    static func parent(of workspace: Workspace, in workspaces: [Workspace], repo: Repository) -> Workspace? {
        let base = repo.localName(forRemoteRef: workspace.baseBranch)
        return workspaces.first { $0.id != workspace.id && $0.branchName == base }
    }

    /// Workspaces stacked directly on `workspace`, in list order.
    static func children(of workspace: Workspace, in workspaces: [Workspace], repo: Repository) -> [Workspace] {
        workspaces.filter {
            $0.id != workspace.id && repo.localName(forRemoteRef: $0.baseBranch) == workspace.branchName
        }
    }

    /// The ref a workspace's base resolves to for ahead/behind and rebase.
    /// Stacked: the local branch of the layer below, whose newest commits
    /// may not be pushed. Otherwise the remote-tracking base, which the
    /// tracker's fetch keeps current.
    static func baseRef(for workspace: Workspace, in workspaces: [Workspace], repo: Repository) -> String {
        parent(of: workspace, in: workspaces, repo: repo)?.branchName ?? repo.remoteRef(workspace.baseBranch)
    }

    /// Whether `workspace` is `base` or sits anywhere above it: stacking
    /// `base` on it would make a loop.
    static func isStacked(_ workspace: Workspace, onTopOf base: Workspace, in workspaces: [Workspace], repo: Repository) -> Bool {
        var seen: Set<String> = []
        var cursor: Workspace? = workspace
        while let ws = cursor, seen.insert(ws.id).inserted {
            if ws.id == base.id { return true }
            cursor = parent(of: ws, in: workspaces, repo: repo)
        }
        return false
    }

    /// Sidebar order: every workspace that isn't stacked on another, in list
    /// order, each followed by the ones stacked on it (depth-first). Depth 0
    /// is a root. A cycle (two branches based on each other) can't come from
    /// Jetline, but a hand-edited base could make one; its members are shown
    /// as roots rather than dropped. `grouped: false` (the user turned stack
    /// grouping off) is the plain list order, every row a root.
    static func sidebarOrder(_ workspaces: [Workspace], repo: Repository, grouped: Bool = true) -> [(workspace: Workspace, depth: Int)] {
        guard grouped else { return workspaces.map { ($0, 0) } }
        let branches = Set(workspaces.map(\.branchName))
        var childrenByBase: [String: [Workspace]] = [:]
        var roots: [Workspace] = []
        for ws in workspaces {
            let base = repo.localName(forRemoteRef: ws.baseBranch)
            if base != ws.branchName, branches.contains(base) {
                childrenByBase[base, default: []].append(ws)
            } else {
                roots.append(ws)
            }
        }

        var out: [(Workspace, Int)] = []
        var placed: Set<String> = []
        func place(_ ws: Workspace, depth: Int) {
            guard placed.insert(ws.id).inserted else { return }
            out.append((ws, depth))
            for child in childrenByBase[ws.branchName] ?? [] { place(child, depth: depth + 1) }
        }
        for ws in roots { place(ws, depth: 0) }
        for ws in workspaces where !placed.contains(ws.id) { place(ws, depth: 0) }
        return out
    }

    /// The full list order after moving the stack rooted at `movedId` into
    /// sidebar gap `gap` (`onMove`'s "insert before" convention; the
    /// sidebar only offers gaps between stacks), each stack kept whole.
    /// Ungrouped, every workspace is its own stack.
    static func reorder(_ workspaces: [Workspace], moving movedId: String, toGap gap: Int, repo: Repository, grouped: Bool = true) -> [String] {
        var groups: [[String]] = []
        for (ws, depth) in sidebarOrder(workspaces, repo: repo, grouped: grouped) {
            if depth == 0 || groups.isEmpty { groups.append([ws.id]) } else { groups[groups.count - 1].append(ws.id) }
        }
        guard let from = groups.firstIndex(where: { $0.first == movedId }) else { return workspaces.map(\.id) }
        // Stacks that start before the gap.
        var rowsBefore = 0
        var to = 0
        for group in groups where rowsBefore < gap {
            rowsBefore += group.count
            to += 1
        }
        let moved = groups.remove(at: from)
        groups.insert(moved, at: min(to > from ? to - 1 : to, groups.count))
        return groups.flatMap { $0 }
    }
}

/// The stack shown in the PR panel: the layers from the top of the stack
/// down to the trunk.
struct StackSummary: Equatable {
    struct Layer: Equatable, Identifiable {
        var id: String
        var number: Int?
        var title: String
        var url: String?
        /// `OPEN` / `CLOSED` / `MERGED`, or `nil` for a layer with no PR yet.
        var state: String?
        var isDraft: Bool
        var branch: String
        var workspaceId: String?
        var isCurrent: Bool
    }

    /// Top first.
    var layers: [Layer]
    var trunk: String
    /// GitHub knows about the stack (it merges and rebases it as one).
    var isOnGitHub: Bool

    /// Builds the stack `workspace` belongs to, or `nil` when it's in none.
    /// A GitHub stack is authoritative for the layers it has; without one
    /// the chain below comes from the local workspaces. Either way, local
    /// workspaces stacked above the top (no PR yet, or one not linked yet)
    /// go on top.
    static func build(
        for workspace: Workspace,
        in workspaces: [Workspace],
        repo: Repository,
        pr: (Workspace) -> PullRequest?
    ) -> StackSummary? {
        let byBranch = Dictionary(workspaces.map { ($0.branchName, $0) }, uniquingKeysWith: { first, _ in first })

        func layer(for ws: Workspace) -> Layer {
            let pull = pr(ws)
            return Layer(
                id: ws.id,
                number: pull?.number,
                title: pull?.title ?? ws.name,
                url: pull?.url,
                state: pull?.state.uppercased(),
                isDraft: pull?.isDraft ?? false,
                branch: ws.branchName,
                workspaceId: ws.id,
                isCurrent: ws.id == workspace.id
            )
        }

        var bottomUp: [Layer]
        let trunk: String
        let onGitHub: Bool
        let top: Workspace?

        if let stack = pr(workspace)?.stack, !stack.entries.isEmpty {
            onGitHub = true
            trunk = stack.baseRefName
            bottomUp = stack.entries.map { entry in
                let ws = byBranch[entry.headRefName]
                return Layer(
                    id: ws?.id ?? "pr-\(entry.number)",
                    number: entry.number,
                    title: entry.title,
                    url: entry.url,
                    state: entry.state.uppercased(),
                    isDraft: entry.isDraft,
                    branch: entry.headRefName,
                    workspaceId: ws?.id,
                    isCurrent: entry.position == stack.position
                )
            }
            top = stack.entries.last.flatMap { byBranch[$0.headRefName] }
        } else {
            onGitHub = false
            var chain: [Workspace] = [workspace]
            var seen: Set<String> = [workspace.id]
            while let parent = WorkspaceStacks.parent(of: chain[0], in: workspaces, repo: repo),
                  seen.insert(parent.id).inserted {
                chain.insert(parent, at: 0)
            }
            trunk = repo.localName(forRemoteRef: chain[0].baseBranch)
            bottomUp = chain.map(layer(for:))
            top = workspace
        }

        // Follows the first child at each level: a stack is a line.
        var seen = Set(bottomUp.map(\.branch))
        var current = top
        while let ws = current,
              let next = WorkspaceStacks.children(of: ws, in: workspaces, repo: repo).first(where: { !seen.contains($0.branchName) }) {
            seen.insert(next.branchName)
            bottomUp.append(layer(for: next))
            current = next
        }

        guard bottomUp.count > 1 else { return nil }
        return StackSummary(layers: bottomUp.reversed(), trunk: trunk, isOnGitHub: onGitHub)
    }
}
