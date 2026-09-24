import AppKit

/// Icons for toolbar `Menu` labels. SwiftUI bridges a toolbar menu's label
/// to an `NSMenuToolbarItem` (image + title), dropping the label's HStack
/// spacing and frame modifiers — AppKit then butts the icon against the
/// title and scales SF Symbols up to toolbar size. Baking the size and a
/// trailing gap into a plain (non-symbol) image sidesteps both.
@MainActor
enum ToolbarLabelIcon {
    static let gap: CGFloat = 5

    private static var cache: [String: NSImage] = [:]

    static func symbol(_ name: String, pointSize: CGFloat = 12) -> NSImage? {
        let key = "sym:\(name):\(pointSize)"
        if let hit = cache[key] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        else { return nil }
        let image = padded(base, size: base.size)
        // Template so the toolbar tints it like a native symbol.
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// Keyed on the source image's identity: `OpenInApp.icon(size:)` hands
    /// back the same cached instance for each app.
    static func app(_ icon: NSImage, side: CGFloat = 14) -> NSImage {
        let key = "app:\(ObjectIdentifier(icon).hashValue):\(side)"
        if let hit = cache[key] { return hit }
        let image = padded(icon, size: NSSize(width: side, height: side))
        cache[key] = image
        return image
    }

    private static func padded(_ source: NSImage, size: NSSize) -> NSImage {
        NSImage(size: NSSize(width: size.width + gap, height: size.height), flipped: false) { _ in
            source.draw(in: NSRect(origin: .zero, size: size))
            return true
        }
    }
}
