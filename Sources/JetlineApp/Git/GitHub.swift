import Foundation

/// Models + thin wrapper around the `gh` CLI. We shell out rather than call
/// the GitHub REST API directly so we inherit the user's existing `gh auth`
/// credentials, host config, and SSO state.

struct PullRequest: Decodable, Sendable, Hashable {
    struct Author: Decodable, Sendable, Hashable {
        var login: String
    }
    var number: Int
    var title: String
    var url: String
    var state: String
    var isDraft: Bool
    var headRefName: String
    var baseRefName: String
    var author: Author
}

enum CheckStatus: Sendable, Hashable, Decodable {
    case queued, inProgress, completed, waiting, requested, pending, unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.uppercased() ?? ""
        switch raw {
        case "QUEUED":      self = .queued
        case "IN_PROGRESS": self = .inProgress
        case "COMPLETED":   self = .completed
        case "WAITING":     self = .waiting
        case "REQUESTED":   self = .requested
        case "PENDING":     self = .pending
        default:            self = .unknown
        }
    }
}

enum CheckConclusion: Sendable, Hashable, Decodable {
    case success, failure, neutral, cancelled, skipped, timedOut, actionRequired, stale, unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.uppercased() ?? ""
        switch raw {
        case "SUCCESS":         self = .success
        case "FAILURE":         self = .failure
        case "NEUTRAL":         self = .neutral
        case "CANCELLED":       self = .cancelled
        case "SKIPPED":         self = .skipped
        case "TIMED_OUT":       self = .timedOut
        case "ACTION_REQUIRED": self = .actionRequired
        case "STALE":           self = .stale
        default:                self = .unknown
        }
    }
}

/// Coarse status assigned by gh — more reliable than `(status, conclusion)`
/// for grouping/coloring because gh already collapses edge cases.
enum CheckBucket: Sendable, Hashable, Decodable {
    case pass, fail, pending, skipping, cancel, unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? ""
        switch raw {
        case "pass":     self = .pass
        case "fail":     self = .fail
        case "pending":  self = .pending
        case "skipping": self = .skipping
        case "cancel":   self = .cancel
        default:         self = .unknown
        }
    }
}

struct CheckRun: Decodable, Sendable, Hashable, Identifiable {
    var name: String
    var status: CheckStatus
    var conclusion: CheckConclusion
    var bucket: CheckBucket
    var link: String?
    var workflow: String?
    var startedAt: String?
    var completedAt: String?

    /// gh `pr checks` doesn't expose a stable id, so combine workflow+name.
    /// Duplicates collapse, which is acceptable for a status list.
    var id: String { "\(workflow ?? "")::\(name)" }

    var isActive: Bool {
        switch status {
        case .queued, .inProgress, .pending, .waiting, .requested:
            return true
        case .completed, .unknown:
            return bucket == .pending
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, bucket, link, workflow, startedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = (try? c.decode(CheckStatus.self, forKey: .status)) ?? .unknown
        conclusion = (try? c.decode(CheckConclusion.self, forKey: .conclusion)) ?? .unknown
        bucket = (try? c.decode(CheckBucket.self, forKey: .bucket)) ?? .unknown
        link = try c.decodeIfPresent(String.self, forKey: .link)
        workflow = try c.decodeIfPresent(String.self, forKey: .workflow)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    }
}

enum PRSnapshot: Equatable, Sendable {
    case loading
    case error(String)
    case absent
    case loaded(PullRequest, [CheckRun])
}

enum GitHubRunner {
    enum Error: LocalizedError {
        case ghMissing
        case authRequired
        case other(String)

        var errorDescription: String? {
            switch self {
            case .ghMissing: return "gh CLI not found on PATH. Install via `brew install gh`."
            case .authRequired: return "gh not authenticated. Run `gh auth login` in a terminal."
            case let .other(msg): return msg
            }
        }
    }

    static func findPullRequest(branch: String, cwd: String) async throws -> PullRequest? {
        let stdout = try await runGH([
            "pr", "list",
            "--head", branch,
            "--state", "all",
            "--limit", "1",
            "--json", "number,title,url,state,isDraft,headRefName,baseRefName,author"
        ], cwd: cwd)
        let prs = try JSONDecoder().decode([PullRequest].self, from: Data(stdout.utf8))
        return prs.first
    }

    static func checks(forPR number: Int, cwd: String) async throws -> [CheckRun] {
        let stdout = try await runGH([
            "pr", "checks", String(number),
            "--json", "name,status,conclusion,bucket,link,workflow,startedAt,completedAt"
        ], cwd: cwd)
        return try JSONDecoder().decode([CheckRun].self, from: Data(stdout.utf8))
    }

    private static func runGH(_ args: [String], cwd: String) async throws -> String {
        let result = await Subprocess.run(
            executable: "/usr/bin/env",
            args: ["gh"] + args,
            cwd: cwd,
            env: [
                "NO_COLOR": "1",
                "GH_NO_UPDATE_NOTIFIER": "1",
                "GH_PAGER": ""
            ],
            closeStdin: true
        )
        if result.success { return result.stdout }

        let lower = result.stderr.lowercased()
        if result.status == -1 || lower.contains("command not found") || lower.contains("no such file") {
            throw Error.ghMissing
        }
        if lower.contains("authentication") || lower.contains("not logged into") || lower.contains("gh auth") {
            throw Error.authRequired
        }
        throw Error.other(result.stderr.nonBlank ?? "gh exited with status \(result.status)")
    }
}
