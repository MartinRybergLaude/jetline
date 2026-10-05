import Foundation

// Jetline patch: SwiftPM's `Bundle.module` only looks next to the app
// bundle's root, where codesign won't allow a resource bundle. The app
// ships SPM resource bundles in `Contents/Resources/`, so look there first.
func mathFontsBundleURL() -> URL? {
    let shipped = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/SwiftMath_SwiftMath.bundle")
    if let bundle = Bundle(url: shipped),
       let url = bundle.url(forResource: "mathFonts", withExtension: "bundle") {
        return url
    }
    return Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")
}
