#if os(macOS)
import Foundation

/// Moves files between this Mac and the engine's machine: images attached
/// to a chat or dropped on a terminal go up, images referenced by a
/// transcript come down into a cache. With a local engine both sides are
/// the same disk and nothing moves.
@MainActor
final class EngineFiles {
    static let shared = EngineFiles()

    private weak var connection: EngineConnection?
    /// Engine path → local file with the same contents.
    private var mirrored: [String: URL] = [:]
    private var inFlight: Set<String> = []

    private static let maxDownload = 32 * 1024 * 1024

    func bind(_ connection: EngineConnection) {
        self.connection = connection
    }

    private var isLocal: Bool { connection?.isLocal ?? true }

    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Jetline/remote-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where `enginePath` can be read on this Mac, if it's here yet.
    func localURL(for enginePath: String) -> URL? {
        if isLocal { return URL(fileURLWithPath: enginePath) }
        if let hit = mirrored[enginePath] { return hit }
        let cached = Self.cachedURL(for: enginePath)
        if FileManager.default.fileExists(atPath: cached.path) {
            mirrored[enginePath] = cached
            return cached
        }
        return nil
    }

    /// Like `localURL`, as a path, falling back to the engine path itself
    /// (which only resolves with a local engine) so callers stay simple.
    func localPath(for enginePath: String) -> String {
        localURL(for: enginePath)?.path ?? enginePath
    }

    /// Put a local file on the engine's machine and return its path there.
    func upload(_ url: URL) async throws -> String {
        if isLocal { return url.path }
        guard let connection else { throw WireError.disconnected }
        let data = try Data(contentsOf: url)
        let remote = try await connection.call(API.UploadFile(name: url.lastPathComponent, data: data))
        mirrored[remote] = url
        return remote
    }

    /// Start fetching `enginePath` into the cache.
    func prefetch(_ enginePath: String) {
        guard !isLocal, localURL(for: enginePath) == nil, !inFlight.contains(enginePath), let connection else { return }
        inFlight.insert(enginePath)
        Task { [weak self] in
            defer { self?.inFlight.remove(enginePath) }
            guard let data = try? await connection.call(API.ReadFile(path: enginePath, maxBytes: Self.maxDownload)) else { return }
            let target = Self.cachedURL(for: enginePath)
            try? data.write(to: target)
            self?.mirrored[enginePath] = target
        }
    }

    private static func cachedURL(for enginePath: String) -> URL {
        var hash: UInt64 = 1469598103934665603
        for byte in enginePath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let ext = (enginePath as NSString).pathExtension
        let name = String(hash, radix: 16) + (ext.isEmpty ? "" : ".\(ext)")
        return cacheDirectory.appendingPathComponent(name)
    }
}
#endif
