// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Jetline",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "jetline", targets: ["JetlineApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.1773686495"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "JetlineApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/JetlineApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "JetlineAppTests",
            dependencies: ["JetlineApp"],
            path: "Tests/JetlineAppTests"
        )
    ]
)
