// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Jetforge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "jetforge", targets: ["JetforgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "JetforgeApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/JetforgeApp"
        ),
        .testTarget(
            name: "JetforgeAppTests",
            dependencies: ["JetforgeApp"],
            path: "Tests/JetforgeAppTests"
        )
    ]
)
