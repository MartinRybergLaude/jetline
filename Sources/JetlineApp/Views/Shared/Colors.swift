import SwiftUI
import AppKit

extension Color {
    /// System green is too light to read as a foreground against the app's
    /// light backgrounds — the same problem `PRPanel.ReviewSection` already
    /// dodges by using orange instead of yellow. This is GitHub's own
    /// light-mode success green (#1A7F37).
    ///
    /// Only the Aqua side is darkened: against the dark backgrounds
    /// (#1E1E1E) the system color is the more legible of the two, and this
    /// darker one would sink into them.
    ///
    /// Use it for green *foregrounds* — text, glyphs, badge dots. Fills that
    /// carry white text (the `OPEN` state pill, the `A` file-status badge)
    /// and low-opacity washes (added-line diff backgrounds) keep the system
    /// color: they're already high-contrast, and darkening them just muddies
    /// the tint.
    static let readableGreen = Color(nsColor: NSColor(name: "readableGreen") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.102, green: 0.498, blue: 0.216, alpha: 1)
    })
}
