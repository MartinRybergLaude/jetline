import Foundation
import GRDB

/// A tab that was running when Jetline last quit, recorded for "reopen
/// sessions on launch". Chats restore from their own threads; a chat row
/// only marks that the workspace had them open.
struct RestorableTab: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        case terminal
        case chat
    }

    var workspaceId: String
    /// Tab position within the workspace, in steps of `orderStep`.
    var displayOrder: Int
    var kind: Kind
    var agent: Workspace.AgentKind

    static let databaseTableName = "session_restore_tabs"
    static let orderStep = 100
}

/// What to bring back in one workspace on launch.
struct SessionRestorePlan: Equatable {
    struct Terminal: Equatable {
        var agent: Workspace.AgentKind
        var launchArgs: [String]
    }

    var workspaceId: String
    var restoresChats: Bool
    var terminals: [Terminal]
}

enum SessionRestore {
    /// Per-workspace plans, in the order workspaces first appear. Only the
    /// first Claude tab of a workspace continues the last conversation —
    /// two `--continue`s would both pick up the same one — and only when
    /// there is one to continue.
    static func plans(
        for tabs: [RestorableTab],
        hasClaudeConversation: (_ workspaceId: String) -> Bool
    ) -> [SessionRestorePlan] {
        var order: [String] = []
        var byWorkspace: [String: [RestorableTab]] = [:]
        for tab in tabs {
            if byWorkspace[tab.workspaceId] == nil { order.append(tab.workspaceId) }
            byWorkspace[tab.workspaceId, default: []].append(tab)
        }
        return order.map { workspaceId in
            let workspaceTabs = (byWorkspace[workspaceId] ?? []).sorted { $0.displayOrder < $1.displayOrder }
            let agents = workspaceTabs.filter { $0.kind == .terminal }.map(\.agent)
            let continuedIndex = agents.firstIndex(of: .claude).flatMap { index in
                hasClaudeConversation(workspaceId) ? index : nil
            }
            let terminals = agents.enumerated().map { index, agent in
                SessionRestorePlan.Terminal(agent: agent, launchArgs: index == continuedIndex ? ["--continue"] : [])
            }
            return SessionRestorePlan(
                workspaceId: workspaceId,
                restoresChats: workspaceTabs.contains { $0.kind == .chat },
                terminals: terminals
            )
        }
    }
}

enum SessionRestoreStore {
    /// Every recorded tab, grouped by workspace in tab order.
    static func all() throws -> [RestorableTab] {
        try Database.shared.writer.read { db in
            try RestorableTab
                .order(Column("workspaceId"), Column("displayOrder"))
                .fetchAll(db)
        }
    }

    /// Replaces the record with what is running now.
    static func replace(with tabs: [RestorableTab]) throws {
        try Database.shared.writer.write { db in
            _ = try RestorableTab.deleteAll(db)
            for tab in tabs {
                try tab.insert(db)
            }
        }
    }
}
