// swift-tools-version:6.2
import PackageDescription

// One library module (`JetlineApp`) holds everything: the headless engine
// (git, worktrees, agents, terminals, persistence), the wire protocol, and —
// on macOS only — the SwiftUI client. Two thin executables sit on top:
//
//   - `jetline`  — the macOS app (client + an in-process engine for local mode)
//   - `jetlined` — the headless daemon, for Linux (and macOS) hosts, that a
//                  remote Jetline app drives over `ssh host jetlined attach`
//
// The UI sources are fenced with `#if os(macOS)` so the same module compiles
// on Linux with only the engine inside. The macOS-only dependencies are
// conditional for the same reason.
let package = Package(
    name: "Jetline",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "jetline", targets: ["JetlineMain"]),
        .executable(name: "jetlined", targets: ["jetlined"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "Vendor/libghostty-spm"),
        .package(path: "Vendor/SwiftMath"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.4")
    ],
    targets: [
        .target(
            name: "CJetlineSys",
            path: "Sources/CJetlineSys"
        ),
        .target(
            name: "JetlineApp",
            dependencies: [
                "CJetlineSys",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm", condition: .when(platforms: [.macOS])),
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
                .product(name: "SwiftMath", package: "SwiftMath", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/JetlineApp",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "JetlineMain",
            dependencies: ["JetlineApp"],
            path: "Sources/JetlineMain"
        ),
        .executableTarget(
            name: "jetlined",
            dependencies: ["JetlineApp"],
            path: "Sources/jetlined"
        ),
        .testTarget(
            name: "JetlineAppTests",
            dependencies: ["JetlineApp"],
            path: "Tests/JetlineAppTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
