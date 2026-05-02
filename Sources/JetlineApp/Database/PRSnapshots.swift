import Foundation
import GRDB

/// Persisted PR snapshot row. We only store ground-truth states (`absent` /
/// `loaded`) — transient `loading` / `error` states are UI-only and never
/// hit disk, so the next launch starts from the last known fact.
struct StoredPRSnapshot: Codable, FetchableRecord, PersistableRecord {
    var workspaceId: String
    var kind: String
    var prJSON: String?
    var checksJSON: String?
    var fetchedAt: Date

    static let databaseTableName = "pr_snapshots"

    enum Columns {
        static let workspaceId = Column(CodingKeys.workspaceId)
        static let kind = Column(CodingKeys.kind)
        static let prJSON = Column(CodingKeys.prJSON)
        static let checksJSON = Column(CodingKeys.checksJSON)
        static let fetchedAt = Column(CodingKeys.fetchedAt)
    }
}

enum PRSnapshots {
    /// Load every persisted snapshot keyed by workspace id. Rows whose JSON
    /// fails to decode are silently dropped — the tracker will overwrite
    /// them on its first poll anyway.
    static func loadAll() throws -> [String: PRSnapshot] {
        let rows = try Database.shared.writer.read { db in
            try StoredPRSnapshot.fetchAll(db)
        }
        var out: [String: PRSnapshot] = [:]
        for row in rows {
            if let snap = decode(row) {
                out[row.workspaceId] = snap
            }
        }
        return out
    }

    /// Persist a snapshot. `loading` / `error` states are intentionally
    /// dropped (they're transient UI states); callers can pass them
    /// unconditionally.
    static func save(_ snap: PRSnapshot, for workspaceId: String) throws {
        guard let row = encode(snap, workspaceId: workspaceId) else { return }
        try Database.shared.writer.write { db in
            try row.save(db)
        }
    }

    static func remove(workspaceId: String) throws {
        _ = try Database.shared.writer.write { db in
            try StoredPRSnapshot.deleteOne(db, key: workspaceId)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func encode(_ snap: PRSnapshot, workspaceId: String) -> StoredPRSnapshot? {
        let now = Date()
        switch snap {
        case .absent:
            return StoredPRSnapshot(
                workspaceId: workspaceId,
                kind: "absent",
                prJSON: nil,
                checksJSON: nil,
                fetchedAt: now
            )
        case let .loaded(pr, checks):
            guard let prData = try? encoder.encode(pr),
                  let checksData = try? encoder.encode(checks) else {
                return nil
            }
            return StoredPRSnapshot(
                workspaceId: workspaceId,
                kind: "loaded",
                prJSON: String(data: prData, encoding: .utf8),
                checksJSON: String(data: checksData, encoding: .utf8),
                fetchedAt: now
            )
        case .loading, .error:
            return nil
        }
    }

    private static func decode(_ row: StoredPRSnapshot) -> PRSnapshot? {
        switch row.kind {
        case "absent":
            return .absent
        case "loaded":
            guard let prData = row.prJSON?.data(using: .utf8),
                  let checksData = row.checksJSON?.data(using: .utf8),
                  let pr = try? decoder.decode(PullRequest.self, from: prData),
                  let checks = try? decoder.decode([CheckRun].self, from: checksData) else {
                return nil
            }
            return .loaded(pr, checks)
        default:
            return nil
        }
    }
}
