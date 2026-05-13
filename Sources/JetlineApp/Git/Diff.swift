import Foundation
import Darwin

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
    /// Throws if the base ref is missing or the underlying `git diff` calls fail.
    ///
    /// Two-phase: `--raw` enumerates changed files with their pre/post blob SHAs
    /// (free — git already has these in the tree), `--numstat` gives counts.
    /// We then look up each `(oldSHA, newSHA)` pair in `HunkCache.shared` and
    /// only fetch + parse `git diff -U3 -- <path>...` for the cache misses.
    /// In steady state (FSEvents tick where most files are unchanged) this skips
    /// ~all of `PatchParser.parse`.
    ///
    /// Pass `precomputedMergeBase` when the caller has already resolved
    /// `merge-base HEAD baseBranch` so we don't repeat the lookup; ignored when
    /// `mode == .local`.
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

        // Phase 1: enumerate changed files + per-file blob SHAs (--raw) and
        // line counts (--numstat) in parallel. Both are cheap tree-walks; no
        // patch text is materialized yet.
        // `git diff` reports tracked paths only, so files an agent just
        // created (never `git add`ed) would not appear in the snapshot at
        // all — the untracked listing fills that gap below.
        async let untrackedTask = GitRunner.run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            cwd: worktreePath
        )
        async let rawTask = GitRunner.runChecked(
            ["diff", "--raw", revspec],
            cwd: worktreePath
        )
        async let numstatTask = GitRunner.runChecked(
            ["diff", "--numstat", revspec],
            cwd: worktreePath
        )

        let rawOut = try await rawTask
        let entries = parseRawDiff(rawOut)

        let numstatOut = try await numstatTask
        var stats: [String: (Int, Int)] = [:]
        for line in numstatOut.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            stats[String(parts[2])] = (adds, dels)
        }

        // Phase 2: split entries into cache hits and misses.
        var cached: [String: HunkCache.Value] = [:]
        var missEntries: [RawEntry] = []
        var missKeys: [String: HunkCache.Key] = [:]
        for entry in entries {
            let key = cacheKey(for: entry, worktreePath: worktreePath)
            if let hit = await HunkCache.shared.get(key) {
                cached[entry.path] = hit
            } else {
                missEntries.append(entry)
                missKeys[entry.path] = key
            }
        }

        // Phase 3: fetch + parse the patch for cache-misses only. Pathspecs
        // limit the patch to the changed subset, so a 23k-line full diff
        // collapses to a per-file fetch on FSEvents-driven refreshes.
        var parsedHunks: [String: HunkCache.Value] = [:]
        if !missEntries.isEmpty {
            var args = ["diff", "--no-color", "-U3", revspec, "--"]
            args.append(contentsOf: missEntries.map(\.path))
            let patchOut = try await GitRunner.runChecked(args, cwd: worktreePath)
            for parsed in PatchParser.parse(patchOut) {
                parsedHunks[parsed.path] = HunkCache.Value(
                    hunks: parsed.hunks,
                    isBinary: parsed.isBinary
                )
            }
            // Persist parsed entries (and empty results — a real "no hunks"
            // answer for this SHA pair, e.g. mode-only changes, deserves a
            // cache entry too so we don't re-fetch).
            for entry in missEntries {
                guard let key = missKeys[entry.path] else { continue }
                let value = parsedHunks[entry.path]
                    ?? HunkCache.Value(hunks: [], isBinary: false)
                await HunkCache.shared.set(key, value)
            }
        }

        // Phase 4: assemble FileDiffs. Order mirrors the historical sort by
        // path so SwiftUI diffing stays stable across refreshes.
        var files: [FileDiff] = []
        var totalAdds = 0
        var totalDels = 0
        for entry in entries {
            let stat = stats[entry.path] ?? (0, 0)
            let payload = cached[entry.path]
                ?? parsedHunks[entry.path]
                ?? HunkCache.Value(hunks: [], isBinary: false)
            files.append(FileDiff(
                path: entry.path,
                status: entry.status,
                additions: stat.0,
                deletions: stat.1,
                hunks: payload.hunks,
                isBinary: payload.isBinary
            ))
            totalAdds += stat.0
            totalDels += stat.1
        }

        // Untracked listing is soft-fail: a hiccup here shouldn't take the
        // tracked diff down with it. Skip paths git already reported — e.g.
        // `git rm --cached` leaves a path both Deleted in the diff and
        // untracked on disk, and duplicate ids would break the panel's
        // ForEach.
        if let untracked = try? await untrackedTask, untracked.success {
            let trackedPaths = Set(files.map(\.path))
            for sub in untracked.stdout.split(separator: "\0") {
                let path = String(sub)
                guard !trackedPaths.contains(path),
                      let file = untrackedFileDiff(path: path, worktreePath: worktreePath)
                else { continue }
                totalAdds += file.additions
                files.append(file)
            }
        }

        files.sort { $0.path < $1.path }
        return DiffSnapshot(files: files, totalAdditions: totalAdds, totalDeletions: totalDels)
    }

    /// Synthesize the `FileDiff` for an untracked file: a single hunk of
    /// pure additions, mirroring what `git diff` would emit once the file
    /// is staged. Content is read straight from disk — one subprocess for
    /// the whole listing instead of a `git diff --no-index /dev/null <path>`
    /// per file. Returns nil when the file vanished between listing and read.
    static func untrackedFileDiff(path: String, worktreePath: String) -> FileDiff? {
        let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        // NUL in the first 8k is git's own binary heuristic. Oversized files
        // get the same not-shown treatment: an agent-created file that large
        // is an artifact, and materializing it as hunk lines would bloat the
        // panel for no reading value.
        if data.prefix(8000).contains(0) || data.count > maxUntrackedPreviewBytes {
            return FileDiff(
                path: path, status: .added, additions: 0, deletions: 0,
                hunks: [], isBinary: true
            )
        }
        guard !data.isEmpty else {
            return FileDiff(path: path, status: .added, additions: 0, deletions: 0, hunks: [])
        }

        // Split on `Character.isNewline`, not the literal "\n": Swift folds
        // "\r\n" into a single grapheme, so a literal-"\n" split leaves CRLF
        // files as one giant line. Matching the whole newline grapheme also
        // keeps the stray "\r" out of the rendered rows.
        var lines = String(decoding: data, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last == "" { lines.removeLast() } // trailing newline isn't a line
        let hunk = FileDiff.Hunk(
            header: "@@ -0,0 +1,\(lines.count) @@",
            lines: lines.map { FileDiff.Line(kind: .addition, text: String($0)) }
        )
        return FileDiff(
            path: path,
            status: .added,
            additions: lines.count,
            deletions: 0,
            hunks: [hunk]
        )
    }

    private static let maxUntrackedPreviewBytes = 4 << 20

    /// Per-entry result of `git diff --raw`. The blob SHAs are git's content
    /// hash for each side; we use them as the cache key.
    fileprivate struct RawEntry {
        var oldSHA: String
        var newSHA: String
        var status: FileDiff.Status
        var path: String
    }

    /// Parse `git diff --raw <revspec>` output. Each line:
    ///   :100644 100644 <oldSHA> <newSHA> <status>\t<path>
    /// Renames/copies emit two paths, tab-separated; we keep the post-rename
    /// path because that's what `--numstat` and `-U3` key on.
    fileprivate static func parseRawDiff(_ raw: String) -> [RawEntry] {
        var entries: [RawEntry] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix(":") else { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let metaParts = parts[0]
                .dropFirst()
                .split(separator: " ", omittingEmptySubsequences: true)
            guard metaParts.count >= 5 else { continue }
            let oldSHA = String(metaParts[2])
            let newSHA = String(metaParts[3])
            let statusField = metaParts[4]
            let statusCode = String(statusField.prefix(1))
            let status = FileDiff.Status(rawValue: statusCode) ?? .modified
            // R/C carry a percent-similarity suffix and emit oldPath\tnewPath;
            // the post-rename path is what every downstream lookup expects.
            let isRenameOrCopy = statusField.hasPrefix("R") || statusField.hasPrefix("C")
            let path: String
            if isRenameOrCopy, parts.count >= 3 {
                path = String(parts[2])
            } else {
                path = String(parts[1])
            }
            entries.append(RawEntry(
                oldSHA: oldSHA,
                newSHA: newSHA,
                status: status,
                path: path
            ))
        }
        return entries
    }

    /// All-zero blob SHA git emits for a "side that isn't a real blob" — the
    /// worktree side in `git diff HEAD`, the old side of an addition, the new
    /// side of a deletion. The first two require disambiguation on the
    /// cache key (the underlying file may have changed even though git's
    /// label is the same constant).
    private static let nullSHA = String(repeating: "0", count: 40)

    /// Build a cache key for a raw diff entry. When git emits the null SHA on
    /// the worktree side (local mode, unstaged changes) we substitute a
    /// `stat`-based fingerprint so an in-place edit invalidates the cache.
    private static func cacheKey(for entry: RawEntry, worktreePath: String) -> HunkCache.Key {
        var refinedNew = entry.newSHA
        if refinedNew == nullSHA {
            refinedNew = statFingerprint(path: entry.path, worktreePath: worktreePath)
                ?? refinedNew
        }
        return HunkCache.Key(oldSHA: entry.oldSHA, newSHA: refinedNew)
    }

    /// `inode.size.mtime_ns` for the worktree file, or nil if the file is
    /// gone. Returning nil leaves the key as the null SHA, which is fine —
    /// a missing worktree file means deletion, and the (oldSHA, null) pair
    /// is genuinely stable across refreshes.
    private static func statFingerprint(path: String, worktreePath: String) -> String? {
        let full = (worktreePath as NSString).appendingPathComponent(path)
        var st = stat()
        guard lstat(full, &st) == 0 else { return nil }
        let mtimeNs = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000
            &+ Int64(st.st_mtimespec.tv_nsec)
        return "stat:\(st.st_ino).\(st.st_size).\(mtimeNs)"
    }
}

/// Process-wide cache of parsed diff hunks keyed on git's blob SHAs. A hit
/// means "the (oldSHA, newSHA) pair has already been parsed in this session,
/// reuse the result" — content-addressed, so the same key collapses
/// across modes (combined / pr / local) and across workspaces in the same
/// repo (and even different worktrees that share blobs).
actor HunkCache {
    static let shared = HunkCache()

    struct Key: Hashable {
        var oldSHA: String
        var newSHA: String
    }

    struct Value {
        var hunks: [FileDiff.Hunk]
        var isBinary: Bool
    }

    private var entries: [Key: Value] = [:]
    /// Cap on entries. Hit when a session walks a lot of file history; we
    /// drop everything rather than implementing LRU because the cost of a
    /// re-fetch on the next compute is bounded and the working set typically
    /// re-warms within a few refreshes.
    private let limit = 4096

    func get(_ key: Key) -> Value? { entries[key] }

    func set(_ key: Key, _ value: Value) {
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = value
    }

    /// Test hook so the parser tests can isolate cache state.
    func clear() { entries.removeAll(keepingCapacity: true) }
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

        // `Character.isNewline` rather than a literal "\n": when the diffed
        // file has CRLF endings, git emits "…\r\n" and Swift folds that into
        // one grapheme a literal split can't cut — every content line of the
        // hunk then glues into a single "+…" row.
        for rawLine in patch.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
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
