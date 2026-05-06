import AppKit

/// Discovers a representative app/site icon inside a repository so the
/// sidebar can render the repo's branding instead of a generic folder
/// glyph. The lookup is a bounded BFS over the repo (skipping vendored /
/// build dirs, scoring candidates by depth and path tokens), which is
/// expensive enough that running it inline from a SwiftUI body would
/// stall the first sidebar paint per repo.
///
/// Lookups are now dispatched on a detached `Task` and the cache is
/// observable: views read `RepoIconLoader.shared.icon(for:)` and observe
/// the loader as an `@ObservedObject`, so the sidebar paints immediately
/// (with the folder fallback) and snaps to the resolved icon when the
/// background scan lands.
@MainActor
final class RepoIconLoader: ObservableObject {
    static let shared = RepoIconLoader()

    /// `nil` value = lookup completed and no icon was found; absence from
    /// the dict = lookup not yet attempted. Storing the negative result
    /// keeps us from re-scanning repos that legitimately have no icon.
    @Published private var cache: [String: NSImage?] = [:]
    /// Paths whose lookup is currently dispatched. Guards against firing
    /// duplicate scans when `icon(for:)` is called many times before the
    /// first scan returns (which is normal — the sidebar repaints on
    /// every AppState publish).
    private var inFlight: Set<String> = []

    private init() {}

    /// Returns the cached icon for `repoPath`, dispatching a background
    /// scan the first time we see it. Re-renders observing views when
    /// the scan lands.
    func icon(for repoPath: String) -> NSImage? {
        if let stored = cache[repoPath] {
            return stored
        }
        guard !inFlight.contains(repoPath) else { return nil }
        inFlight.insert(repoPath)
        Task.detached(priority: .userInitiated) {
            let image = Self.lookup(at: repoPath)
            await self.store(image: image, for: repoPath)
        }
        return nil
    }

    private func store(image: NSImage?, for path: String) {
        cache[path] = image
        inFlight.remove(path)
    }

    nonisolated private static let validExtensions: Set<String> = ["svg", "ico", "png"]

    nonisolated private static let iconStems: Set<String> = ["favicon", "appicon", "app-icon", "app_icon", "icon"]

    nonisolated private static let skipDirs: Set<String> = [
        "node_modules", ".git", ".next", ".nuxt", ".svelte-kit",
        "dist", "build", "target", "out", "coverage",
        ".turbo", ".cache", ".parcel-cache",
        "vendor", "Pods", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".swiftpm", ".build", "DerivedData"
    ]

    nonisolated private static let maxDepth = 5

    nonisolated private static let demoteTokens = [
        "storybook", "docs", "doc", "demo", "example", "examples",
        "playground", "fixture", "fixtures", "sandbox", "tests", "__tests__"
    ]

    nonisolated private static let promoteTokens = [
        "web", "app", "apps", "frontend", "client", "www", "site"
    ]

    /// Pure: safe to call from a detached Task. NSImage construction
    /// reads file data only — actual rendering happens later on main when
    /// SwiftUI displays the image, which is the thread-touchy step.
    nonisolated private static func lookup(at repoPath: String) -> NSImage? {
        let base = URL(fileURLWithPath: repoPath, isDirectory: true)
        var queue: [(URL, Int)] = [(base, 0)]
        var candidates: [(url: URL, depth: Int)] = []
        let fm = FileManager.default

        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents {
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                if iconStems.contains(stem), validExtensions.contains(ext) {
                    candidates.append((url, depth))
                }
                if ext == "icns" {
                    candidates.append((url, depth))
                }
                if ext == "appiconset", let resolved = resolveAppIconSet(at: url) {
                    candidates.append((resolved, depth))
                }
            }

            if depth >= maxDepth { continue }

            for url in contents {
                guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir else { continue }
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                if ext == "icon" || ext == "appiconset" { continue }
                if skipDirs.contains(name) || name.hasPrefix(".") { continue }
                queue.append((url, depth + 1))
            }
        }

        let scored = candidates
            .map { (url: $0.url, score: score($0.url, depth: $0.depth)) }
            .sorted { $0.score > $1.score }

        for candidate in scored {
            if let image = NSImage(contentsOf: candidate.url) {
                return image
            }
        }
        return nil
    }

    nonisolated private static func resolveAppIconSet(at url: URL) -> URL? {
        let contentsURL = url.appendingPathComponent("Contents.json")
        if let data = try? Data(contentsOf: contentsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let images = json["images"] as? [[String: Any]] {
            var best: (pixels: Int, url: URL)?
            for image in images {
                guard let filename = image["filename"] as? String else { continue }
                let pixels = parseDimension(image["size"] as? String) * parseScale(image["scale"] as? String)
                let candidate = url.appendingPathComponent(filename)
                if best == nil || pixels > best!.pixels {
                    best = (pixels, candidate)
                }
            }
            if let best { return best.url }
        }
        return largestPNG(in: url)
    }

    nonisolated private static func largestPNG(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter { $0.pathExtension.lowercased() == "png" }
            .max { a, b in
                let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sa < sb
            }
    }

    nonisolated private static func parseDimension(_ s: String?) -> Int {
        guard let s, let dim = s.split(separator: "x").first, let n = Int(dim) else { return 0 }
        return n
    }

    nonisolated private static func parseScale(_ s: String?) -> Int {
        guard let s, let n = Int(s.replacingOccurrences(of: "x", with: "")) else { return 1 }
        return n
    }

    nonisolated private static func score(_ url: URL, depth: Int) -> Int {
        let components = url.pathComponents.map { $0.lowercased() }
        var score = -depth * 2
        for component in components {
            if demoteTokens.contains(component) { score -= 100 }
            if promoteTokens.contains(component) { score += 10 }
        }
        return score
    }
}
