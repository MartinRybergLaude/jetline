import Foundation

/// Computed diff snapshot used by the inspector's Changes panel.
struct DiffSnapshot: Equatable {
    var files: [FileDiff]
    var totalAdditions: Int
    var totalDeletions: Int

    static let empty = DiffSnapshot(files: [], totalAdditions: 0, totalDeletions: 0)
}

struct FileDiff: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var status: Status
    var additions: Int
    var deletions: Int
    var hunks: [Hunk]

    enum Status: String {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case typeChange = "T"
        case copied = "C"
        case unknown = "?"

        var label: String {
            switch self {
            case .added: return "Added"
            case .modified: return "Modified"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .typeChange: return "Type change"
            case .copied: return "Copied"
            case .unknown: return "Untracked"
            }
        }
    }

    struct Hunk: Equatable {
        var header: String
        var lines: [Line]
    }

    struct Line: Equatable {
        var kind: Kind
        var text: String

        enum Kind {
            case context
            case addition
            case deletion
        }
    }
}

enum DiffComputer {
    /// Diff worktree (tracked files only) against `baseBranch`.
    /// Throws if the base ref is missing or any of the three `git diff` calls fail —
    /// callers decide how to surface that.
    static func compute(worktreePath: String, baseBranch: String) async throws -> DiffSnapshot {
        let mergeBase = try await GitRunner.runChecked(
            ["merge-base", "HEAD", baseBranch],
            cwd: worktreePath
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // numstat for tallies
        let numstatOut = try await GitRunner.runChecked(
            ["diff", "--numstat", mergeBase],
            cwd: worktreePath
        )
        var stats: [String: (Int, Int)] = [:]
        for line in numstatOut.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            stats[String(parts[2])] = (adds, dels)
        }

        // name-status for status flags
        let nameStatusOut = try await GitRunner.runChecked(
            ["diff", "--name-status", mergeBase],
            cwd: worktreePath
        )
        var statuses: [String: FileDiff.Status] = [:]
        for line in nameStatusOut.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let code = String(parts[0].prefix(1))
            statuses[String(parts[1])] = FileDiff.Status(rawValue: code) ?? .unknown
        }

        // Patch for hunks
        let patchOut = try await GitRunner.runChecked(
            ["diff", "--no-color", "-U3", mergeBase],
            cwd: worktreePath
        )
        let parsed = PatchParser.parse(patchOut)

        var files: [FileDiff] = []
        var totalAdds = 0
        var totalDels = 0
        for parsedFile in parsed {
            let stat = stats[parsedFile.path] ?? (0, 0)
            let status = statuses[parsedFile.path] ?? .modified
            let file = FileDiff(
                path: parsedFile.path,
                status: status,
                additions: stat.0,
                deletions: stat.1,
                hunks: parsedFile.hunks
            )
            files.append(file)
            totalAdds += stat.0
            totalDels += stat.1
        }
        files.sort { $0.path < $1.path }
        return DiffSnapshot(files: files, totalAdditions: totalAdds, totalDeletions: totalDels)
    }
}

/// Parses `git diff` unified-format output into per-file hunks.
enum PatchParser {
    struct ParsedFile {
        var path: String
        var hunks: [FileDiff.Hunk]
    }

    static func parse(_ patch: String) -> [ParsedFile] {
        var files: [ParsedFile] = []
        var currentFile: ParsedFile?
        var currentHunk: FileDiff.Hunk?

        func flushHunk() {
            if var h = currentHunk, var f = currentFile {
                f.hunks.append(h)
                currentFile = f
                currentHunk = nil
                _ = h
            }
        }

        func flushFile() {
            flushHunk()
            if let f = currentFile { files.append(f) }
            currentFile = nil
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                flushFile()
                let path = extractPath(fromDiffHeader: line) ?? ""
                currentFile = ParsedFile(path: path, hunks: [])
            } else if line.hasPrefix("+++ ") {
                // Use +++ to refine path (handles renames)
                let after = String(line.dropFirst(4))
                if after != "/dev/null", currentFile != nil {
                    let trimmed = after.hasPrefix("b/") ? String(after.dropFirst(2)) : after
                    currentFile?.path = trimmed
                }
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHunk = FileDiff.Hunk(header: line, lines: [])
            } else if currentHunk != nil {
                let kind: FileDiff.Line.Kind
                let text: String
                if line.hasPrefix("+") {
                    kind = .addition
                    text = String(line.dropFirst())
                } else if line.hasPrefix("-") {
                    kind = .deletion
                    text = String(line.dropFirst())
                } else if line.hasPrefix(" ") {
                    kind = .context
                    text = String(line.dropFirst())
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file"
                    continue
                } else {
                    continue
                }
                currentHunk?.lines.append(FileDiff.Line(kind: kind, text: text))
            }
        }
        flushFile()
        return files
    }

    private static func extractPath(fromDiffHeader header: String) -> String? {
        // "diff --git a/foo/bar b/foo/bar"
        let parts = header.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let bPart = String(parts[3])
        return bPart.hasPrefix("b/") ? String(bPart.dropFirst(2)) : bPart
    }
}
