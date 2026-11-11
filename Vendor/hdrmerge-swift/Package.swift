// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hdrmerge-swift",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HDRMergeCore", targets: ["HDRMergeCore"]),
        .executable(name: "hdrmerge-swift", targets: ["hdrmerge-swift"]),
    ],
    targets: [
        .target(
            name: "HDRMergeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hdrmerge-swift",
            dependencies: ["HDRMergeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HDRMergeCoreTests",
            dependencies: ["HDRMergeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
