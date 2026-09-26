import AppKit

/// Fetches and caches GitHub avatars for the comment timeline.
///
/// A cache that views read synchronously and a detached fetch that fills
/// it in, so a panel paints immediately with initials and snaps to the real
/// image when it lands (announced by `didLoad`, with the URL as object).
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()
    static let didLoad = Notification.Name("AvatarLoader.didLoad")

    /// `nil` value = fetch finished and produced nothing (404, not an
    /// image, offline); absence from the dict = not yet attempted. Storing
    /// the negative result stops a broken URL from being retried on every
    /// repaint.
    private var cache: [String: NSImage?] = [:]
    /// FIFO eviction order. Avatars are ~4KB each, but the key space is
    /// unbounded over a long session across many repos.
    private var order: [String] = []
    private var inFlight: Set<String> = []

    private static let capacity = 300

    private init() {}

    /// Cached avatar for `url`, kicking off a download the first time it's
    /// asked for.
    func image(for url: String) -> NSImage? {
        if let stored = cache[url] { return stored }
        guard !inFlight.contains(url), let parsed = URL(string: url) else { return nil }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            let image = await Self.fetch(parsed)
            await self.store(image, for: url)
        }
        return nil
    }

    private func store(_ image: NSImage?, for url: String) {
        if cache[url] == nil { order.append(url) }
        cache[url] = image
        inFlight.remove(url)
        while order.count > Self.capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        NotificationCenter.default.post(name: Self.didLoad, object: url)
    }

    /// `URLSession.shared` is backed by `URLCache.shared`, so repeat views of
    /// the same PR — and often a later launch — serve from disk without a
    /// round trip.
    nonisolated private static func fetch(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }
}
