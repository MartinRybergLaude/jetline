#if os(Linux)
import Foundation
import Glibc

/// Recursive directory watcher on inotify, the Linux stand-in for FSEvents.
///
/// inotify watches single directories, so this walks the tree once at start
/// (pruning whatever `skip` rejects — git-ignored directories, `.git`) and
/// adds a watch per directory, then follows directories created or moved in
/// later. `extraDirectories` (the worktree's git-dir) are watched flat:
/// HEAD and the index live at their top level, and their object store is
/// far too large to walk.
///
/// Delivers the changed paths on the main actor. A queue overflow reports
/// an empty batch, which the owner treats as "something changed".
@MainActor
final class InotifyTreeWatcher {
    private let root: String
    private let extraDirectories: [String]
    private let skip: (String) -> Bool
    private let onEvents: ([String]) -> Void

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var directories: [Int32: String] = [:]
    private var exhausted = false

    private static let mask: UInt32 = UInt32(
        IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO
        | IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF
    )

    init(
        root: String,
        extraDirectories: [String],
        skip: @escaping (String) -> Bool,
        onEvents: @escaping ([String]) -> Void
    ) {
        self.root = root
        self.extraDirectories = extraDirectories
        self.skip = skip
        self.onEvents = onEvents
    }

    func start() {
        guard fd < 0 else { return }
        fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return }
        addTree(root)
        for dir in extraDirectories { addWatch(dir) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        let fd = self.fd
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
        directories.removeAll()
    }

    private func addWatch(_ path: String) {
        guard fd >= 0, !exhausted else { return }
        let wd = inotify_add_watch(fd, path, Self.mask)
        if wd >= 0 {
            directories[wd] = path
        } else if errno == ENOSPC {
            // Out of watches (`fs.inotify.max_user_watches`). Keep what we
            // have; the rest of the tree just won't refresh on its own.
            exhausted = true
            FileHandle.standardError.write(Data("jetline: inotify watch limit reached under \(root)\n".utf8))
        }
    }

    private func addTree(_ path: String) {
        guard !skip(path) else { return }
        addWatch(path)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            addTree(child.path)
        }
    }

    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var paths: [String] = []
        var overflowed = false
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            var offset = 0
            let headerSize = MemoryLayout<inotify_event>.size
            while offset + headerSize <= n {
                let (wd, mask, len): (Int32, UInt32, Int) = buffer.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: offset)
                    let wd = base.loadUnaligned(as: Int32.self)
                    let mask = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                    let len = base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                    return (wd, mask, Int(len))
                }
                var name = ""
                if len > 0 {
                    let start = offset + headerSize
                    let slice = buffer[start..<min(start + len, n)]
                    name = String(decoding: slice.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                offset += headerSize + len

                if mask & UInt32(IN_Q_OVERFLOW) != 0 {
                    overflowed = true
                    continue
                }
                if mask & UInt32(IN_IGNORED) != 0 {
                    directories.removeValue(forKey: wd)
                    continue
                }
                guard let dir = directories[wd] else { continue }
                let path = name.isEmpty ? dir : dir + "/" + name
                paths.append(path)
                if mask & UInt32(IN_ISDIR) != 0,
                   mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0,
                   !extraDirectories.contains(dir) {
                    addTree(path)
                }
            }
        }
        if overflowed {
            onEvents([])
        } else if !paths.isEmpty {
            onEvents(paths)
        }
    }
}
#endif
