import Foundation
import GRDB

enum Schema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "repositories") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("defaultBranch", .text).notNull().defaults(to: "main")
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime)
            }

            try db.create(table: "workspaces") { t in
                t.column("id", .text).primaryKey()
                t.column("repositoryId", .text).notNull()
                    .references("repositories", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("branchName", .text).notNull()
                t.column("baseBranch", .text).notNull()
                t.column("worktreePath", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastActiveAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
            }
            try db.create(index: "idx_workspaces_repo", on: "workspaces", columns: ["repositoryId"])

            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("workspaceId", .text).notNull()
                    .references("workspaces", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.create(index: "idx_sessions_workspace", on: "sessions", columns: ["workspaceId"])

            try db.create(table: "app_settings") { t in
                t.column("id", .text).primaryKey()
                t.column("defaultAgent", .text).notNull().defaults(to: "claude")
                t.column("claudeBinaryPath", .text)
                t.column("codexBinaryPath", .text)
                t.column("terminalFontFamily", .text).notNull().defaults(to: "SF Mono")
                t.column("terminalFontSize", .double).notNull().defaults(to: 13)
                t.column("theme", .text).notNull().defaults(to: "system")
            }
        }

        migrator.registerMigration("v2_repo_settings") { db in
            try db.alter(table: "repositories") { t in
                t.add(column: "remoteOrigin", .text).notNull().defaults(to: "origin")
                t.add(column: "branchPrefix", .text)
                t.add(column: "setupScript", .text)
                t.add(column: "runScript", .text)
                t.add(column: "runExclusive", .boolean).notNull().defaults(to: false)
                t.add(column: "archiveScript", .text)
            }
            try db.alter(table: "app_settings") { t in
                t.add(column: "globalBranchPrefix", .text).notNull().defaults(to: "jetline/")
            }
        }

        migrator.registerMigration("v3_agent_visibility") { db in
            try db.alter(table: "app_settings") { t in
                t.add(column: "mistralBinaryPath", .text)
                t.add(column: "hiddenAgents", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v4_open_in_app") { db in
            try db.alter(table: "app_settings") { t in
                t.add(column: "defaultOpenInApp", .text).notNull().defaults(to: "finder")
            }
        }

        migrator.registerMigration("v5_pr_snapshots") { db in
            try db.create(table: "pr_snapshots") { t in
                t.column("workspaceId", .text).primaryKey()
                    .references("workspaces", onDelete: .cascade)
                t.column("kind", .text).notNull()  // "absent" | "loaded"
                t.column("prJSON", .text)
                t.column("checksJSON", .text)
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v6_git_actions") { db in
            try db.alter(table: "app_settings") { t in
                t.add(column: "gitAgent", .text)
                t.add(column: "reviewAgent", .text)
                t.add(column: "commitPrompt", .text)
                t.add(column: "createPRPrompt", .text)
                t.add(column: "pullUpdatesPrompt", .text)
                t.add(column: "fixCIPrompt", .text)
                t.add(column: "fixCommentsPrompt", .text)
                t.add(column: "reviewPrompt", .text)
            }
            try db.alter(table: "repositories") { t in
                t.add(column: "commitPrompt", .text)
                t.add(column: "createPRPrompt", .text)
                t.add(column: "pullUpdatesPrompt", .text)
                t.add(column: "fixCIPrompt", .text)
                t.add(column: "fixCommentsPrompt", .text)
                t.add(column: "reviewPrompt", .text)
            }
        }

        migrator.registerMigration("v7_last_merge_method") { db in
            try db.alter(table: "repositories") { t in
                t.add(column: "lastMergeMethod", .text)
            }
        }

        migrator.registerMigration("v8_rebase_on_main_prompt") { db in
            try db.alter(table: "app_settings") { t in
                t.add(column: "rebaseOnMainPrompt", .text)
            }
            try db.alter(table: "repositories") { t in
                t.add(column: "rebaseOnMainPrompt", .text)
            }
        }

        migrator.registerMigration("v9_branch_prefix_mode") { db in
            try db.alter(table: "repositories") { t in
                // Discriminator for the new branch-prefix UI: "username" |
                // "custom" | "none". Existing rows stay nil so the legacy
                // fallback (custom value or inherited global) keeps working.
                t.add(column: "branchPrefixMode", .text)
            }
        }

        migrator.registerMigration("v10_drop_sessions") { db in
            try db.drop(table: "sessions")
        }

        migrator.registerMigration("v11_drop_global_branch_prefix") { db in
            try db.alter(table: "app_settings") { t in
                t.drop(column: "globalBranchPrefix")
            }
        }

        migrator.registerMigration("v12_repo_sort_index") { db in
            try db.alter(table: "repositories") { t in
                t.add(column: "sortIndex", .integer).notNull().defaults(to: 0)
            }
            // Backfill in the order rows were displayed pre-migration so the
            // first launch after upgrading shows the same arrangement the
            // user is used to. Subsequent reorders rewrite the column.
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM repositories
                ORDER BY lastOpenedAt DESC, createdAt DESC
                """)
            for (idx, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE repositories SET sortIndex = ? WHERE id = ?",
                    arguments: [idx, id]
                )
            }
        }

        migrator.registerMigration("v13_onboarding") { db in
            try db.alter(table: "app_settings") { t in
                t.add(column: "hasCompletedOnboarding", .boolean)
                    .notNull().defaults(to: false)
            }
        }
    }
}
