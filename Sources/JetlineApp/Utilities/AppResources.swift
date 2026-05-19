import Foundation

extension Bundle {
    /// Resource bundle resolver that places assets under the conventional
    /// `Contents/Resources/` path. SwiftPM's auto-generated `Bundle.module`
    /// expects the bundle at `Bundle.main.bundleURL/<name>.bundle` (the .app
    /// root, sibling of `Contents/`). That layout makes codesign reject the
    /// app with "unsealed contents present in the bundle root", so the
    /// Makefile copies SPM resource bundles into `Contents/Resources/`
    /// instead and we read them from there. Never call `Bundle.module` —
    /// its lazy initializer fatalErrors when the bundle isn't found at one
    /// of its two hardcoded paths.
    static let jetlineResources: Bundle = {
        let inResources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Jetline_JetlineApp.bundle")
        if let b = Bundle(path: inResources.path) { return b }

        let buildPath = Bundle.main.bundleURL
            .appendingPathComponent("Jetline_JetlineApp.bundle")
        if let b = Bundle(path: buildPath.path) { return b }

        return .main
    }()
}
