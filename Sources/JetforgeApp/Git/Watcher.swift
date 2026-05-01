import Foundation

/// Coalesced filesystem watcher backed by FSEvents.
/// Fires `onChange` after any change inside the worktree, throttled.
final class WorktreeWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    private var pendingTask: Task<Void, Never>?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
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
            watcher.scheduleNotify()
        }
        let pathArray = [path] as CFArray
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
        FSEventStreamStart(s)
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
            await MainActor.run { self?.onChange() }
        }
    }
}
