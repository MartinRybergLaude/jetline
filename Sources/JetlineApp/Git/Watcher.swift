import Foundation

/// Coalesced filesystem watcher backed by FSEvents.
/// Fires `onChange` after any change inside the worktree, throttled.
///
/// Pinned to the main actor so the throttle Task and the `onChange` callback
/// share the same isolation domain — FSEvents already dispatches on `.main`,
/// so we just have to bridge that into actor space via `assumeIsolated`.
@MainActor
final class WorktreeWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: @MainActor () -> Void
    private var pendingTask: Task<Void, Never>?

    init(paths: [String], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            // Dispatched on `.main` (set below), so we're guaranteed to be on
            // the main thread — matches MainActor isolation.
            MainActor.assumeIsolated { watcher.scheduleNotify() }
        }
        let pathArray = paths as CFArray
        let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
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
