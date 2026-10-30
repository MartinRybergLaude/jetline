import Foundation

/// The commits a workspace's diff was computed from. While neither moves,
/// only working-tree edits can change the diff.
struct DiffCommitKey: Equatable, Sendable {
    let head: String
    let base: String
}

extension DiffComputer {
    /// HEAD's and the base branch's commit hashes, in one `rev-parse`.
    /// `nil` when either doesn't resolve (unborn HEAD, missing base).
    static func commitKey(worktreePath: String, baseBranch: String) async -> DiffCommitKey? {
        let result = try? await GitRunner.run(
            ["rev-parse", "HEAD^{commit}", "\(baseBranch)^{commit}"],
            cwd: worktreePath
        )
        guard let result, result.success else { return nil }
        let hashes = result.stdout.split(separator: "\n").map(String.init)
        guard hashes.count == 2 else { return nil }
        return DiffCommitKey(head: hashes[0], base: hashes[1])
    }
}

/// When a workspace's diff is redone under "Low git performance": a move
/// of its commit hashes redoes it at once, while working-tree writes only
/// mark it pending for the engine's slow poll.
@MainActor
final class DiffRefreshGate {
    /// The interval at which pending working-tree writes are picked up.
    static let pollInterval: Duration = .seconds(30)

    private var keys: [String: DiffCommitKey] = [:]
    /// Workspaces with working-tree writes their diff doesn't show yet.
    private(set) var pending: Set<String> = []

    func markPending(_ id: String) {
        pending.insert(id)
    }

    /// A full refresh is about to read the working tree.
    func refreshStarted(_ id: String) {
        pending.remove(id)
    }

    func refreshed(_ id: String, at key: DiffCommitKey?) {
        keys[id] = key
    }

    /// Whether the diff was computed from other commits than `key`. An
    /// unresolvable key always counts, so failures err toward refreshing.
    func commitsMoved(_ key: DiffCommitKey?, for id: String) -> Bool {
        guard let key else { return true }
        return keys[id] != key
    }

    func forget(_ id: String) {
        keys[id] = nil
        pending.remove(id)
    }
}
