import SwiftUI

extension EnvironmentValues {
    /// Font family chosen for assistant messages in Settings; `nil` → system
    /// font. Everything else in the chat stays on the system font.
    @Entry var chatFontFamily: String?
}

extension Font {
    static func chat(size: CGFloat, family: String?) -> Font {
        family.map { .custom($0, fixedSize: size) } ?? .system(size: size)
    }
}
