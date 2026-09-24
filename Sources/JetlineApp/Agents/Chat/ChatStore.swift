import Foundation
import GRDB

extension AgentProviderKind: DatabaseValueConvertible {}
extension AgentRuntimeMode: DatabaseValueConvertible {}
extension AgentInteractionMode: DatabaseValueConvertible {}

struct ChatThreadRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_threads"

    var id: String
    var workspaceId: String
    var provider: AgentProviderKind
    var title: String
    var model: String?
    var effort: String?
    var runtimeMode: AgentRuntimeMode
    var interactionMode: AgentInteractionMode
    /// JSON-encoded `AgentResumeCursor`.
    var resumeCursor: String?
    /// JSON-encoded `[AgentTodo]`.
    var todos: String?
    var createdAt: Date
    var updatedAt: Date
    /// Set when the tab closes. The transcript stays, so the chat can be
    /// reopened from the new-tab menu.
    var closedAt: Date?

    enum Columns {
        static let workspaceId = Column(CodingKeys.workspaceId)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let closedAt = Column(CodingKeys.closedAt)
    }
}

struct ChatTurnRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_turns"

    var id: String
    var threadId: String
    var seq: Int
    var providerTurnId: String?
    var status: String
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date?
    var checkpointBefore: String?
    var checkpointAfter: String?
    /// JSON-encoded `Checkpointer.Stat`.
    var stat: String?
}

struct ChatItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_items"

    var id: String
    var threadId: String
    var turnId: String
    var seq: Int
    /// JSON-encoded `AgentItem`.
    var payload: Data
    var createdAt: Date?
}

/// Persistence for native chats. Writes go through GRDB's serial
/// `asyncWrite` queue, so they apply in the order the chat issued them
/// without blocking the main actor.
enum ChatStore {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder = JSONDecoder()

    // MARK: Threads

    static func openThreads(workspaceId: String) -> [ChatThreadRecord] {
        (try? Database.shared.writer.read { db in
            try ChatThreadRecord
                .filter(ChatThreadRecord.Columns.workspaceId == workspaceId)
                .filter(ChatThreadRecord.Columns.closedAt == nil)
                .order(ChatThreadRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }) ?? []
    }

    static func closedThreads(workspaceId: String, limit: Int = 10) -> [ChatThreadRecord] {
        (try? Database.shared.writer.read { db in
            try ChatThreadRecord
                .filter(ChatThreadRecord.Columns.workspaceId == workspaceId)
                .filter(ChatThreadRecord.Columns.closedAt != nil)
                .order(ChatThreadRecord.Columns.updatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    static func thread(id: String) -> ChatThreadRecord? {
        try? Database.shared.writer.read { db in try ChatThreadRecord.fetchOne(db, key: id) }
    }

    static func save(_ thread: ChatThreadRecord) {
        write { db in try thread.save(db) }
    }

    static func setClosed(_ threadId: String, closed: Bool) {
        write { db in
            try db.execute(
                sql: "UPDATE chat_threads SET closedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [closed ? Date() : nil, Date(), threadId]
            )
        }
    }

    static func deleteThread(_ threadId: String) {
        write { db in _ = try ChatThreadRecord.deleteOne(db, key: threadId) }
    }

    static func threadIds(workspaceId: String) -> [String] {
        (try? Database.shared.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM chat_threads WHERE workspaceId = ?", arguments: [workspaceId])
        }) ?? []
    }

    static func deleteThreads(workspaceId: String) {
        write { db in
            try db.execute(sql: "DELETE FROM chat_threads WHERE workspaceId = ?", arguments: [workspaceId])
        }
    }

    // MARK: Transcript

    static func transcript(threadId: String) -> (turns: [ChatTurnRecord], items: [ChatItemRecord]) {
        (try? Database.shared.writer.read { db in
            let turns = try ChatTurnRecord
                .filter(Column("threadId") == threadId)
                .order(Column("seq").asc)
                .fetchAll(db)
            let items = try ChatItemRecord
                .filter(Column("threadId") == threadId)
                .order(Column("seq").asc)
                .fetchAll(db)
            return (turns, items)
        }) ?? ([], [])
    }

    static func save(_ turn: ChatTurnRecord) {
        write { db in try turn.save(db) }
    }

    static func save(_ item: ChatItemRecord) {
        write { db in try item.save(db) }
    }

    /// Drop turns from `seq` on, with their items — used by revert.
    static func truncate(threadId: String, fromSeq seq: Int) {
        write { db in
            let turnIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM chat_turns WHERE threadId = ? AND seq >= ?",
                arguments: [threadId, seq]
            )
            guard !turnIds.isEmpty else { return }
            try db.execute(
                sql: "DELETE FROM chat_items WHERE threadId = ? AND turnId IN (\(databaseQuestionMarks(count: turnIds.count)))",
                arguments: StatementArguments([threadId] + turnIds)
            )
            try db.execute(
                sql: "DELETE FROM chat_turns WHERE threadId = ? AND seq >= ?",
                arguments: [threadId, seq]
            )
        }
    }

    private static func write(_ updates: @escaping @Sendable (GRDB.Database) throws -> Void) {
        Database.shared.writer.asyncWrite(updates) { _, result in
            if case let .failure(error) = result {
                NSLog("Jetline chat store write failed: \(error)")
            }
        }
    }
}
