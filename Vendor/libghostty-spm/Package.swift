// swift-tools-version: 6.0
import PackageDescription

// Vendored, trimmed copy of github.com/Lakr233/libghostty-spm.
//
// Why vendored: upstream aggressively prunes git tags and deletes old
// GitHub release assets, so a pinned `.binaryTarget(url:)` 404s the moment
// they cut a new version (it has broken our CI repeatedly). Here the binary
// target points at a release asset on our own repo, which we never delete,
// and the wrapper sources live in-tree — so upstream churn can't break us.
//
// Trimmed to only what Jetline imports: GhosttyKit (C re-export) and
// GhosttyTerminal (Swift wrapper). GhosttyTheme and ShellCraftKit are
// dropped. MSDisplayLink (also Lakr233's, also tag-pruned) is folded in as
// a target instead of a remote dependency, leaving zero external deps.
//
// To update to upstream version X.Y.Z:
//   1. gh release create libghostty-spm-X.Y.Z <zip> --latest=false  (mirror
//      upstream's storage.X.Y.Z/GhosttyKit.xcframework.zip onto this repo)
//   2. swift package compute-checksum <zip>  → paste into `checksum` below
//   3. refresh Sources/{GhosttyKit,GhosttyTerminal,MSDisplayLink} from the
//      upstream checkout, and update the `url` tag below.
let package = Package(
    name: "libghostty-spm",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "MSDisplayLink",
            path: "Sources/MSDisplayLink"
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/MartinRybergLaude/jetline/releases/download/libghostty-spm-1.2.1/GhosttyKit.xcframework.zip",
            checksum: "8333a035ae372ef39f7dff26affaa1f3dac4129a52251aa3264828700b784071"
        ),
    ]
)
