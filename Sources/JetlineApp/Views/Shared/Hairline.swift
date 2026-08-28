import SwiftUI

/// A one-physical-pixel line in the system separator colour.
///
/// Prefer this over `Divider()` where the line has to sit on an exact edge
/// next to AppKit's own chrome: `Divider()` infers its orientation from the
/// enclosing layout — leaving it ambiguous inside an `.overlay` — and draws a
/// full point, which reads heavier than the hairlines AppKit puts beside it.
struct Hairline: View {
    enum Orientation { case horizontal, vertical }

    var orientation: Orientation = .horizontal

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: orientation == .vertical ? 1 / displayScale : nil,
                height: orientation == .horizontal ? 1 / displayScale : nil
            )
    }
}
