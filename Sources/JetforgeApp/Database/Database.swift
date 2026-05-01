import Foundation
import GRDB

/// SQLite-backed persistence using GRDB.
/// Database lives at `~/.jetforge/jetforge.sqlite`
/// (override with `JETFORGE_DATA_DIR`).
final class Database {
    static let shared: Database = {
        do {
            return try Database()
        } catch {
            fatalError("Failed to open database: \(error)")
        }
    }()

    let writer: any DatabaseWriter

    private init() throws {
        let dataDir = Database.dataDirectory()
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let url = dataDir.appendingPathComponent("jetforge.sqlite")
        let pool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        Schema.register(in: &migrator)
        try migrator.migrate(pool)

        self.writer = pool

        try ensureSettingsRow()
    }

    static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["JETFORGE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jetforge", isDirectory: true)
    }

    static var worktreesDirectory: URL {
        dataDirectory().appendingPathComponent("worktrees", isDirectory: true)
    }

    private func ensureSettingsRow() throws {
        try writer.write { db in
            if try AppSettings.fetchOne(db, key: AppSettings.singletonId) == nil {
                try AppSettings().insert(db)
            }
        }
    }
}
