import Foundation
import GRDB

/// Read/write operations grouped by domain. All async, all hop off the main actor.
enum Repositories {
    static func all() throws -> [Repository] {
        try Database.shared.writer.read { db in
            try Repository
                .order(
                    Repository.Columns.sortIndex.asc,
                    Repository.Columns.lastOpenedAt.desc,
                    Repository.Columns.createdAt.desc
                )
                .fetchAll(db)
        }
    }

    static func add(name: String, path: String, defaultBranch: String) throws -> Repository {
        try Database.shared.writer.write { db in
            // Sit above the current min so a fresh add lands at the top of
            // the sidebar, matching the in-memory `insert(at: 0)` AppState
            // does. Subsequent reorders rewrite indices to 0…n-1, so the
            // negative drift here doesn't accumulate.
            let minIdx = try Int.fetchOne(db, sql: "SELECT MIN(sortIndex) FROM repositories") ?? 0
            var repo = Repository(
                id: UUID().uuidString,
                name: name,
                path: path,
                defaultBranch: defaultBranch,
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            repo.sortIndex = minIdx - 1
            try repo.insert(db)
            return repo
        }
    }

    /// Persist a manual sidebar ordering. Writes 0…n-1 across the supplied
    /// id sequence in a single transaction.
    static func reorder(orderedIds: [String]) throws {
        try Database.shared.writer.write { db in
            for (idx, id) in orderedIds.enumerated() {
                try Repository
                    .filter(key: id)
                    .updateAll(db, Repository.Columns.sortIndex.set(to: idx))
            }
        }
    }

    static func update(_ repo: Repository) throws {
        try Database.shared.writer.write { db in
            try repo.update(db)
        }
    }

    static func remove(id: String) throws {
        _ = try Database.shared.writer.write { db in
            try Repository.deleteOne(db, key: id)
        }
    }

    static func touch(id: String) throws {
        _ = try Database.shared.writer.write { db in
            try Repository
                .filter(key: id)
                .updateAll(db, Repository.Columns.lastOpenedAt.set(to: Date()))
        }
    }
}

enum Workspaces {
    static func forRepository(_ repoId: String) throws -> [Workspace] {
        try Database.shared.writer.read { db in
            try Workspace
                .filter(Workspace.Columns.repositoryId == repoId)
                .filter(Workspace.Columns.archivedAt == nil)
                .order(Workspace.Columns.lastActiveAt.desc)
                .fetchAll(db)
        }
    }

    static func insert(_ ws: Workspace) throws {
        try Database.shared.writer.write { db in
            try ws.insert(db)
        }
    }

    static func archive(id: String) throws {
        _ = try Database.shared.writer.write { db in
            try Workspace
                .filter(key: id)
                .updateAll(db, Workspace.Columns.archivedAt.set(to: Date()))
        }
    }

    static func touch(id: String) throws {
        _ = try Database.shared.writer.write { db in
            try Workspace
                .filter(key: id)
                .updateAll(db, Workspace.Columns.lastActiveAt.set(to: Date()))
        }
    }
}

enum SettingsStore {
    static func load() throws -> AppSettings {
        try Database.shared.writer.read { db in
            try AppSettings.fetchOne(db, key: AppSettings.singletonId) ?? AppSettings()
        }
    }

    static func save(_ s: AppSettings) throws {
        var copy = s
        copy.id = AppSettings.singletonId
        try Database.shared.writer.write { db in
            try copy.update(db)
        }
    }
}
