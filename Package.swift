// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Jetforge",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "jetforge", targets: ["JetforgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.1773686495")
    ],
    targets: [
        .executableTarget(
            name: "JetforgeApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "Sources/JetforgeApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "JetforgeAppTests",
            dependencies: ["JetforgeApp"],
            path: "Tests/JetforgeAppTests"
        )
    ]
)
