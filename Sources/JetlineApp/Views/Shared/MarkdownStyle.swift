import CoreGraphics

/// Type sizes for rendered markdown. Kept as explicit point sizes rather
/// than semantic `Font`s because headings need to scale relative to the
/// body size, and the inspector runs smaller than system body text.
struct MarkdownStyle: Hashable {
    var bodySize: CGFloat = 12
    var codeSize: CGFloat = 11
    /// Vertical gap between sibling blocks.
    var blockSpacing: CGFloat = 8
    /// Family for non-code text; `nil` → system font.
    var fontFamily: String?
    /// Family for code; `nil` → system monospaced font.
    var monoFamily: String?
    /// Table text size; `nil` → `bodySize`.
    var tableBodySize: CGFloat?
    /// Extra leading between wrapped lines.
    var lineSpacing: CGFloat = 0

    static let comment = MarkdownStyle(bodySize: 13.5, codeSize: 12.5, blockSpacing: 9)
    /// Slightly tighter, for the quoted body of an inline review thread.
    static let compact = MarkdownStyle(bodySize: 13, codeSize: 12, blockSpacing: 7)

    /// GitHub's own heading ramp, rebased on the body size. h5/h6 sit below
    /// body size, which is what makes deep headings read as labels.
    func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  return bodySize + 6
        case 2:  return bodySize + 4
        case 3:  return bodySize + 2
        case 4:  return bodySize + 1
        case 5:  return bodySize
        default: return bodySize - 1
        }
    }
}
