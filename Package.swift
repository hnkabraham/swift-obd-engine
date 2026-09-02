// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OBDEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OBDModels", targets: ["OBDModels"]),
        .library(name: "OBDEngine", targets: ["OBDEngine"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OBDModels",
            path: "Sources/OBDModels"
        ),
        .target(
            name: "OBDEngine",
            dependencies: ["OBDModels"],
            path: "Sources/OBDEngine"
        ),
        .testTarget(
            name: "OBDEngineTests",
            dependencies: ["OBDEngine", "OBDModels"],
            path: "Tests/OBDEngineTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
