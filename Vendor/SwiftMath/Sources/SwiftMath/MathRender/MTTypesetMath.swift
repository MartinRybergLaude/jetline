import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#endif

// Jetline addition: a typeset formula with its metrics and a draw call that
// takes the color per draw, so text on screen can follow appearance changes
// without re-typesetting.
public final class MTTypesetMath {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    private let display: MTMathListDisplay
    /// Setting a color re-creates every line in the display, so it's only
    /// set when it changes.
    private var appliedColor: CGColor?

    /// Nil when `latex` doesn't parse.
    public init?(latex: String, fontSize: CGFloat, displayStyle: Bool) {
        var error: NSError?
        guard let font = MTFontManager.fontManager.latinModernFont(withSize: fontSize),
              let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil,
              let display = MTTypesetter.createLineForMathList(list, font: font, style: displayStyle ? .display : .text)
        else { return nil }
        self.display = display
        width = display.width
        ascent = display.ascent
        descent = display.descent
    }

    /// Draws with the baseline's left end at `origin`, in a y-up context.
    public func draw(_ context: CGContext, baseline origin: CGPoint, color: MTColor) {
        if appliedColor != color.cgColor {
            display.textColor = color
            appliedColor = color.cgColor
        }
        display.position = origin
        display.draw(context)
    }
}
