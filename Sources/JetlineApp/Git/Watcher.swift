import Foundation

/// Coalesced filesystem watcher backed by FSEvents. Fires `onChange`
/// after any change inside the worktree, throttled.
///
/// Pinned to the main actor so the throttle Task and the `onChange`
/// callback share the same isolation domain — FSEvents already
/// dispatches on `.main`, so we just have to bridge that into actor
/// space via `assumeIsolated`.
///
/// Events that fall entirely under git-ignored directories are dropped
/// before they reach `onChange`. The ignored-prefix set is sourced from
/// `git ls-files --others --ignored --exclude-standard --directory`,
/// loaded asynchronously on `start()` and refreshed when an event
/// touches a `.gitignore` file. Until the load lands, every tick fires
/// (conservative — same behaviour as before this filter existed). The
/// auxiliary watched paths (the worktree's git-dir) are never filtered;
/// commits update HEAD/index there and we always want to see those.
@MainActor
final class WorktreeWatcher {
    private var stream: FSEventStreamRef?
    /// The worktree root. Events under this prefix are subject to the
    /// gitignore filter.
    private let worktreePath: String
    /// Extra dirs the watcher arms (typically the worktree's `.git/worktrees/<id>`
    /// dir for HEAD/index visibility). Events under any of these always
    /// pass through unfiltered.
    private let additionalPaths: [String]
    private let onChange: @MainActor () -> Void
    private var pendingTask: Task<Void, Never>?

    /// Absolute paths (with trailing slash) of git-ignored directories
    /// under `worktreePath`. Empty until the first load completes.
    private var ignoredPrefixes: [String] = []
    private var ignoredLoaded = false
    private var ignoredReload: Task<Void, Never>?

    init(
        worktreePath: String,
        additionalPaths: [String] = [],
        onChange: @escaping @MainActor () -> Void
    ) {
        self.worktreePath = worktreePath
        self.additionalPaths = additionalPaths
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, numEvents, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            // With `kFSEventStreamCreateFlagUseCFTypes` set below, eventPaths
            // is a CFArrayRef of CFStringRef. Without that flag the parameter
            // is a quasi-array of `char *` pointers and casting to NSArray
            // crashes inside `objc_msgSend(retain)` the moment we touch it.
            let cfArray = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue()
            let paths = cfArray as? [String] ?? []
            // Dispatched on `.main` (set below), so we're guaranteed to be on
            // the main thread — matches MainActor isolation.
            MainActor.assumeIsolated {
                watcher.handleEvents(paths: paths, count: numEvents)
            }
        }
        let watchPaths = ([worktreePath] + additionalPaths) as CFArray
        let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
            )
        )
        guard let s else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        // FSEventStreamStart returns false on failure (rare — usually
        // permissions or fd exhaustion). Without cleanup the stream ref
        // leaks for the watcher's lifetime.
        guard FSEventStreamStart(s) else {
            FSEventStreamSetDispatchQueue(s, nil)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
        loadIgnoredPrefixes()
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        pendingTask?.cancel()
        pendingTask = nil
        ignoredReload?.cancel()
        ignoredReload = nil
    }

    private func handleEvents(paths: [String], count: Int) {
        // No paths reported (rare — FSEvents can emit zero-payload ticks
        // on stream-level events). Treat conservatively: fire and let the
        // existing dedupe-on-equality in `refreshDiff` no-op if nothing
        // actually changed.
        guard !paths.isEmpty else {
            scheduleNotify()
            return
        }
        if didTouchGitignore(paths) {
            // .gitignore changed; the cached prefix set is now stale.
            // Refresh in the background; in the meantime keep using the
            // current set (worst case: one extra fire on a real change).
            reloadIgnoredPrefixes()
        }
        if shouldFire(paths: paths) {
            scheduleNotify()
        }
    }

    private func shouldFire(paths: [String]) -> Bool {
        // Until the ignored set is populated we don't know what to skip,
        // so fire on every event — same behaviour as before the filter.
        guard ignoredLoaded else { return true }
        for path in paths {
            if isInteresting(path) { return true }
        }
        return false
    }

    private func isInteresting(_ path: String) -> Bool {
        // Auxiliary paths (git-dir) are always relevant — commits write
        // HEAD/index there and we need to refresh the diff snapshot.
        for extra in additionalPaths where path.hasPrefix(extra) {
            return true
        }
        // Anything outside the worktree (and outside additional paths)
        // shouldn't normally appear. Treat as relevant defensively.
        guard path.hasPrefix(worktreePath) else { return true }
        for prefix in ignoredPrefixes where path.hasPrefix(prefix) {
            return false
        }
        return true
    }

    private func didTouchGitignore(_ paths: [String]) -> Bool {
        for path in paths where path.hasSuffix("/.gitignore") {
            return true
        }
        return false
    }

    private func loadIgnoredPrefixes() {
        ignoredReload?.cancel()
        let path = worktreePath
        ignoredReload = Task { [weak self] in
            let prefixes = await WorktreeWatcher.fetchIgnoredPrefixes(worktreePath: path)
            await MainActor.run {
                guard let self else { return }
                self.ignoredPrefixes = prefixes
                self.ignoredLoaded = true
                self.ignoredReload = nil
            }
        }
    }

    /// Cancels any in-flight reload and starts a new one. Used after a
    /// `.gitignore` mod so newly-added ignore rules take effect without
    /// waiting for the next watcher restart.
    private func reloadIgnoredPrefixes() {
        loadIgnoredPrefixes()
    }

    /// Returns absolute, trailing-slash prefixes of git-ignored
    /// directories under `worktreePath`. Empty array on git failure
    /// (treated as "nothing ignored", which means the watcher is just
    /// as chatty as before — never less correct).
    nonisolated private static func fetchIgnoredPrefixes(worktreePath: String) async -> [String] {
        guard let raw = try? await GitRunner.runChecked(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"],
            cwd: worktreePath
        ) else { return [] }
        let separator = worktreePath.hasSuffix("/") ? "" : "/"
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                // git emits relative paths; directories already carry a
                // trailing `/` thanks to `--directory`.
                "\(worktreePath)\(separator)\(line)"
            }
    }

    private func scheduleNotify() {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
