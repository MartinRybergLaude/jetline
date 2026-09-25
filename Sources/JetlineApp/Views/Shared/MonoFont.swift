import SwiftUI
import AppKit

/// The font families picked under Settings → Appearance, mirrored from
/// `AppSettings` by `AppState`. Observable: a SwiftUI view that reads them
/// redraws when one changes, and AppKit code reads the same values.
@MainActor @Observable
final class FontSettings {
    static let shared = FontSettings()

    /// `AppSettings.monospaceFontFamily`; `nil` → SF Mono.
    private(set) var mono: String?
    /// `AppSettings.chatFontFamily`; `nil` → the system font.
    private(set) var chat: String?

    /// Only assigns what changed, so unrelated settings edits don't redraw
    /// every view that reads a family.
    func apply(_ settings: AppSettings) {
        if mono != settings.monospaceFontFamily { mono = settings.monospaceFontFamily }
        if chat != settings.chatFontFamily { chat = settings.chatFontFamily }
    }
}

/// The monospace font picked under Settings → Appearance, used by the
/// terminal, diffs, code in the chat and every other monospaced label.
/// `nil` → the system monospaced font (SF Mono).
@MainActor
enum MonoFont {
    static var family: String? { FontSettings.shared.mono }

    /// Family name handed to libghostty, which resolves SF Mono by name.
    static func terminalFamily(_ family: String?) -> String { family ?? "SF Mono" }

    static func ns(size: CGFloat, weight: NSFont.Weight = .regular, family: String? = MonoFont.family) -> NSFont {
        guard let family else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let key = "\(family)|\(size)|\(weight.rawValue)"
        if let cached = customFonts[key] { return cached }
        let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: managerWeight(weight), size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
        customFonts[key] = font
        return font
    }

    /// Family lookups by `NSFontManager` search the installed fonts; the
    /// chat timeline asks for the same few per text node.
    private static var customFonts: [String: NSFont] = [:]

    /// Point size at which `monoFamily` has the same x-height as
    /// `textFamily` at `size`. Monospace faces run taller and wider than
    /// text faces at equal point sizes, so code set at the body size reads
    /// bigger than the words around it.
    static func matchedSize(_ size: CGFloat, textFamily: String?, monoFamily: String?) -> CGFloat {
        let key = "\(textFamily ?? "")|\(monoFamily ?? "")"
        let ratio: CGFloat
        if let cached = xHeightRatios[key] {
            ratio = cached
        } else {
            let text = textFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 100) }
                ?? .systemFont(ofSize: 100)
            let mono = ns(size: 100, family: monoFamily)
            ratio = mono.xHeight > 0 && text.xHeight > 0 ? text.xHeight / mono.xHeight : 1
            xHeightRatios[key] = ratio
        }
        return (size * ratio * 2).rounded() / 2
    }

    private static var xHeightRatios: [String: CGFloat] = [:]

    /// Installed families whose glyphs are all one width.
    static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { family in
            !family.hasPrefix(".")
                && NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// `NSFontManager`'s 0–15 weight scale.
    static func managerWeight(_ weight: NSFont.Weight?) -> Int {
        switch weight {
        case .medium?: return 6
        case .semibold?: return 8
        case .bold?, .heavy?, .black?: return 9
        default: return 5
        }
    }
}

extension Font {
    static func mono(size: CGFloat, weight: Font.Weight = .regular, family: String?) -> Font {
        guard let family else { return .system(size: size, weight: weight, design: .monospaced) }
        return .custom(family, fixedSize: size).weight(weight)
    }
}

private struct MonoFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.mono(size: size, weight: weight, family: MonoFont.family))
    }
}

extension View {
    /// Monospaced text in the user's chosen family.
    func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(MonoFontModifier(size: size, weight: weight))
    }

    /// Monospaced text in the user's chosen family, at a text style's size.
    func monoFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        monoFont(size: NSFont.preferredFont(forTextStyle: style.appKit).pointSize, weight: weight)
    }
}

private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}
