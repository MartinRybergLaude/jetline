import Foundation
import AppKit
import GRDB

/// External applications that can open a workspace's worktree directory.
enum OpenInApp: String, Codable, CaseIterable, DatabaseValueConvertible, Hashable {
    case finder
    case ghostty
    case zed
    case vscode
    case cursor

    var displayName: String {
        switch self {
        case .finder: return "Finder"
        case .ghostty: return "Ghostty"
        case .zed: return "Zed"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .finder: return "com.apple.finder"
        case .ghostty: return "com.mitchellh.ghostty"
        case .zed: return "dev.zed.Zed"
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        }
    }

    var appURL: URL? { OpenInAppCache.shared.url(for: self) }

    var isInstalled: Bool { appURL != nil }

    var icon: NSImage? {
        guard let url = appURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Sized copy for use in SwiftUI `Menu` items, where the rendered native
    /// menu sizes the icon from `NSImage.size` rather than SwiftUI frames.
    /// Cached because SwiftUI re-renders the toolbar/menu on every state
    /// change and `NSImage.copy()` is not free.
    func icon(size: CGFloat) -> NSImage? {
        OpenInAppCache.shared.sizedIcon(for: self, size: size)
    }

    /// Open the given directory in this app. Finder uses `activateFileViewerSelecting`
    /// so the folder is highlighted in its parent; others receive the folder URL
    /// directly via `NSWorkspace.shared.open(_:withApplicationAt:configuration:_:)`.
    func open(directory path: String) {
        let url = URL(fileURLWithPath: path)
        if self == .finder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        guard let app = appURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, _ in }
    }
}

private final class OpenInAppCache: @unchecked Sendable {
    static let shared = OpenInAppCache()

    private let lock = NSLock()
    private var urls: [OpenInApp: URL] = [:]
    private var icons: [String: NSImage] = [:]

    func url(for app: OpenInApp) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let cached = urls[app] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
            return nil
        }
        urls[app] = url
        return url
    }

    func sizedIcon(for app: OpenInApp, size: CGFloat) -> NSImage? {
        let key = "\(app.rawValue)@\(size)"
        lock.lock(); defer { lock.unlock() }
        if let cached = icons[key] { return cached }
        guard let url = urls[app] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier),
              let copy = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else {
            return nil
        }
        urls[app] = url
        copy.size = NSSize(width: size, height: size)
        icons[key] = copy
        return copy
    }
}
