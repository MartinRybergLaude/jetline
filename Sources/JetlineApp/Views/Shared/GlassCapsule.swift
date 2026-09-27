#if os(macOS)
import SwiftUI

enum GlassCapsule {
    /// Shared by the chat composer's pills and the merge footer's buttons,
    /// so the two bars line up.
    static let height: CGFloat = 28
}

extension View {
    /// Interactive glass capsule of the shared bar height. A `fill` washes
    /// the capsule itself rather than tinting the glass: tinted glass goes
    /// gray in an inactive window.
    func glassCapsule(fill: Color?, horizontalPadding: CGFloat = 12) -> some View {
        frame(height: GlassCapsule.height)
            .padding(.horizontal, horizontalPadding)
            .background(Capsule().fill(fill ?? .clear))
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}
#endif
