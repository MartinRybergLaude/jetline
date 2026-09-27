#if os(macOS)
import SwiftUI

extension Font {
    static func chat(size: CGFloat, family: String?) -> Font {
        family.map { .custom($0, fixedSize: size) } ?? .system(size: size)
    }
}
#endif
