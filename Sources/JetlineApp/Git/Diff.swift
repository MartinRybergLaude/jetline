import Foundation

/// Computed diff snapshot used by the inspector's Changes panel.
struct DiffSnapshot: Equatable {
    var files: [FileDiff]
    var totalAdditions: Int
    var totalDeletions: Int

    static let empty = DiffSnapshot(files: [], totalAdditions: 0, totalDeletions: 0)

    var isEmpty: Bool { files.isEmpty }
}

struct FileDiff: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var status: Status
    var additions: Int
    var deletions: Int
    var hunks: [Hunk]
    /// True if git emitted "Binary files … differ" (or "GIT binary patch")
    /// for this entry. UI uses it to suppress empty-hunk rendering and show
    /// a "binary" hint instead.
    var isBinary: Bool = false

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

enum DiffMode: Hashable {
    case combined
    case local

    var needsMergeBase: Bool { self != .local }

    func revspec(mergeBase: String?) -> String {
        switch self {
        case .combined: return mergeBase ?? "HEAD"
        case .local:    return "HEAD"
        }
    }
}

enum DiffComputer {
    /// Whether the working tree or index has uncommitted changes — what the
    /// Commit button keys off. Cheap (`git status --porcelain`). Returns
    /// `false` on any error so a transient git failure doesn't keep the
    /// Commit button stuck enabled.
    static func hasUncommittedChanges(worktreePath: String) async -> Bool {
        let result = try? await GitRunner.run(["status", "--porcelain"], cwd: worktreePath)
        guard let result, result.success else { return false }
        return result.stdout.nonBlank != nil
    }

    /// Resolve `merge-base HEAD baseBranch`. Hoisted so the caller can share
    /// one resolution across the three diff modes — combined and pr need the
    /// same SHA, and re-running it for each is two extra subprocesses per
    /// `refreshDiff` tick.
    static func mergeBase(worktreePath: String, baseBranch: String) async throws -> String {
        try await GitRunner.runChecked(
            ["merge-base", "HEAD", baseBranch],
            cwd: worktreePath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diff (tracked files only) against the revspec implied by `mode`.
    /// Throws if the base ref is missing or any of the three `git diff` calls fail —
    /// callers decide how to surface that. Pass `precomputedMergeBase` when the
    /// caller has already resolved `merge-base HEAD baseBranch` so we don't
    /// repeat the lookup; ignored when `mode == .local`.
    static func compute(
        worktreePath: String,
        baseBranch: String,
        mode: DiffMode = .combined,
        precomputedMergeBase: String? = nil
    ) async throws -> DiffSnapshot {
        let mergeBase: String?
        if mode.needsMergeBase {
            if let pre = precomputedMergeBase {
                mergeBase = pre
            } else {
                mergeBase = try await Self.mergeBase(
                    worktreePath: worktreePath,
                    baseBranch: baseBranch
                )
            }
        } else {
            mergeBase = nil
        }
        let revspec = mode.revspec(mergeBase: mergeBase)

        // numstat / name-status / patch are independent reads against the
        // same revspec — fan them out so the wall time is max(of three)
        // instead of sum.
        async let numstatTask = GitRunner.runChecked(
            ["diff", "--numstat", revspec],
            cwd: worktreePath
        )
        async let nameStatusTask = GitRunner.runChecked(
            ["diff", "--name-status", revspec],
            cwd: worktreePath
        )
        async let patchTask = GitRunner.runChecked(
            ["diff", "--no-color", "-U3", revspec],
            cwd: worktreePath
        )

        let numstatOut = try await numstatTask
        var stats: [String: (Int, Int)] = [:]
        for line in numstatOut.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            stats[String(parts[2])] = (adds, dels)
        }

        let nameStatusOut = try await nameStatusTask
        var statuses: [String: FileDiff.Status] = [:]
        for line in nameStatusOut.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let code = String(parts[0].prefix(1))
            statuses[String(parts[1])] = FileDiff.Status(rawValue: code) ?? .unknown
        }

        let patchOut = try await patchTask
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
                hunks: parsedFile.hunks,
                isBinary: parsedFile.isBinary
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
        var isBinary: Bool = false
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
                // Use +++ to refine path (handles renames). Path may be
                // git-quoted ("\"b/foo bar\"") when it contains spaces or
                // non-ASCII bytes — same encoding as the diff --git header.
                let after = String(line.dropFirst(4))
                if after != "/dev/null", currentFile != nil {
                    let unquoted: String
                    if after.hasPrefix("\""), after.hasSuffix("\""), after.count >= 2 {
                        unquoted = unquoteCStyle(String(after.dropFirst().dropLast()))
                    } else {
                        unquoted = after
                    }
                    let trimmed = unquoted.hasPrefix("b/")
                        ? String(unquoted.dropFirst(2))
                        : unquoted
                    currentFile?.path = trimmed
                }
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                flushHunk()
                currentFile?.isBinary = true
                // Stop accumulating hunks for this file; binary patch content
                // following "GIT binary patch" is base85-encoded deltas, not
                // unified-diff text.
                currentHunk = nil
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

    /// Recover the b-side path from a `diff --git ...` header. Handles both
    /// the bare form (`diff --git a/foo b/foo`) and git's quoted form for
    /// paths with spaces or non-ASCII bytes (`diff --git "a/foo bar" "b/foo
    /// bar"`). For bare headers we anchor on the last occurrence of ` b/`,
    /// not index-based splitting, so filenames containing spaces parse
    /// correctly. The +++ refinement downstream still wins for non-rename,
    /// non-binary cases — this parse is what binary and rename diffs rely on.
    private static func extractPath(fromDiffHeader header: String) -> String? {
        let prefix = "diff --git "
        guard header.hasPrefix(prefix) else { return nil }
        let rest = header.dropFirst(prefix.count)

        if rest.last == "\"" {
            // Quoted b-path: scan back for the matching unescaped opening quote.
            let chars = Array(rest)
            var i = chars.count - 2
            while i >= 0 {
                if chars[i] == "\"" {
                    // Count preceding backslashes; even count = unescaped quote.
                    var bs = 0
                    var k = i - 1
                    while k >= 0, chars[k] == "\\" { bs += 1; k -= 1 }
                    if bs % 2 == 0 {
                        let inner = String(chars[(i + 1)..<(chars.count - 1)])
                        let unquoted = unquoteCStyle(inner)
                        return unquoted.hasPrefix("b/")
                            ? String(unquoted.dropFirst(2))
                            : unquoted
                    }
                }
                i -= 1
            }
            return nil
        }

        // Bare: take everything after the last " b/".
        if let range = rest.range(of: " b/", options: .backwards) {
            return String(rest[range.upperBound...])
        }
        return nil
    }

    /// Decode git's C-style quoted-path encoding: `\n`, `\t`, `\r`, `\\`, `\"`,
    /// and 1–3-digit octal byte escapes (used for non-ASCII bytes when
    /// `core.quotePath` is on). Returns the original substring's bytes
    /// reassembled as UTF-8.
    private static func unquoteCStyle(_ s: String) -> String {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "\\" else {
                bytes.append(contentsOf: String(c).utf8)
                i = s.index(after: i)
                continue
            }
            let next = s.index(after: i)
            guard next < s.endIndex else {
                bytes.append(0x5C)
                break
            }
            let n = s[next]
            switch n {
            case "n":  bytes.append(0x0A); i = s.index(after: next)
            case "t":  bytes.append(0x09); i = s.index(after: next)
            case "r":  bytes.append(0x0D); i = s.index(after: next)
            case "\\": bytes.append(0x5C); i = s.index(after: next)
            case "\"": bytes.append(0x22); i = s.index(after: next)
            case "0", "1", "2", "3":
                var j = next
                var val: UInt8 = 0
                var count = 0
                while count < 3, j < s.endIndex,
                      let d = s[j].asciiValue, d >= 0x30 && d <= 0x37 {
                    val = (val &* 8) &+ (d - 0x30)
                    j = s.index(after: j)
                    count += 1
                }
                bytes.append(val)
                i = j
            default:
                bytes.append(0x5C)
                i = next
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
