// swift-tools-version: 5.7
import PackageDescription

// Vendored from https://github.com/mgriebling/SwiftMath at
// 1d2c90827e9c3908269d810d055fb03b7da5fd53 (MIT). Patches:
//   - `mathFontsBundleURL()` (ResourceBundle.swift) replaces `Bundle.module`,
//     which can't find the bundle inside a signed Jetline.app.
//   - Only Latin Modern Math is shipped; the other eleven fonts are dropped.
//   - Font-registration debugPrints are silenced.
//   - `MTTypesetMath` (MTTypesetMath.swift) exposes typeset metrics and drawing.
//   - MTTypesetter, MTAtomTokenizer: operator limits go above/below in display style only,
//     as in TeX; inline `\sum_{i}^{n}` sets them as scripts.
let package = Package(
    name: "SwiftMath",
    platforms: [.macOS("12.0")],
    products: [
        .library(name: "SwiftMath", targets: ["SwiftMath"]),
    ],
    targets: [
        .target(
            name: "SwiftMath",
            resources: [.copy("mathFonts.bundle")]
        ),
    ]
)
