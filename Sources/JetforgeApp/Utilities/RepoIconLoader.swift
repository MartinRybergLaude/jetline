import AppKit

@MainActor
enum RepoIconLoader {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for repoPath: String) -> NSImage? {
        if let cached = cache[repoPath] { return cached }
        let image = lookup(at: repoPath)
        cache[repoPath] = image
        return image
    }

    private static let validExtensions: Set<String> = ["svg", "ico", "png"]

    private static let skipDirs: Set<String> = [
        "node_modules", ".git", ".next", ".nuxt", ".svelte-kit",
        "dist", "build", "target", "out", "coverage",
        ".turbo", ".cache", ".parcel-cache",
        "vendor", "Pods", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".swiftpm", ".build", "DerivedData"
    ]

    private static let maxDepth = 5

    private static let demoteTokens = [
        "storybook", "docs", "doc", "demo", "example", "examples",
        "playground", "fixture", "fixtures", "sandbox", "tests", "__tests__"
    ]

    private static let promoteTokens = [
        "web", "app", "apps", "frontend", "client", "www", "site"
    ]

    private static func lookup(at repoPath: String) -> NSImage? {
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
                if stem == "favicon", validExtensions.contains(ext) {
                    candidates.append((url, depth))
                }
            }

            if depth >= maxDepth { continue }

            for url in contents {
                guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir else { continue }
                let name = url.lastPathComponent
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

    private static func score(_ url: URL, depth: Int) -> Int {
        let components = url.pathComponents.map { $0.lowercased() }
        var score = -depth * 2
        for component in components {
            if demoteTokens.contains(component) { score -= 100 }
            if promoteTokens.contains(component) { score += 10 }
        }
        return score
    }
}
