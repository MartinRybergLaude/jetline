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
    /// Use it for green foregrounds — text, glyphs, badge dots — and for the
    /// fills that sit next to them: the PR panel's `Open` and `Approved`
    /// chips and its merge button all take this green, because system green
    /// beside a `readableGreen` check mark reads as a second, brighter green
    /// rather than the same status.
    ///
    /// Low-opacity washes (added-line diff backgrounds) and the small
    /// `A` file-status badge keep the system color: they carry no
    /// `readableGreen` neighbor, and darkening a wash just muddies it.
    static let readableGreen = Color(nsColor: NSColor(name: "readableGreen") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.102, green: 0.498, blue: 0.216, alpha: 1)
    })
}
