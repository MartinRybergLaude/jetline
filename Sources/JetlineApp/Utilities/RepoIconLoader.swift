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
                if ext == "icns" {
                    candidates.append((url, depth))
                }
                if ext == "icon", let resolved = resolveIconPackage(at: url) {
                    candidates.append((resolved, depth))
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

    private static func resolveIconPackage(at url: URL) -> URL? {
        let assets = url.appendingPathComponent("Assets", isDirectory: true)
        let jsonURL = url.appendingPathComponent("icon.json")
        if let data = try? Data(contentsOf: jsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let groups = json["groups"] as? [[String: Any]] {
            for group in groups where (group["hidden"] as? Bool) != true {
                guard let layers = group["layers"] as? [[String: Any]] else { continue }
                for layer in layers where (layer["hidden"] as? Bool) != true {
                    if let name = layer["image-name"] as? String {
                        let candidate = assets.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            return candidate
                        }
                    }
                }
            }
        }
        return largestPNG(in: assets)
    }

    private static func resolveAppIconSet(at url: URL) -> URL? {
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

    private static func largestPNG(in dir: URL) -> URL? {
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

    private static func parseDimension(_ s: String?) -> Int {
        guard let s, let dim = s.split(separator: "x").first, let n = Int(dim) else { return 0 }
        return n
    }

    private static func parseScale(_ s: String?) -> Int {
        guard let s, let n = Int(s.replacingOccurrences(of: "x", with: "")) else { return 1 }
        return n
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
