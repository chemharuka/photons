// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NonlocalMatchFilter",
    platforms: [.macOS(.v14)],
    products: [
        // The library a host app links against. No CLI, no subprocess: the
        // network is MIT, so it goes in-process.
        .library(name: "NonlocalMatchFilter", targets: ["NonlocalMatchFilter"]),
        // A small CLI for batch work and for reproducing the numbers in
        // RESULTS.md without an app around it.
        .executable(name: "nlmf-denoise", targets: ["nlmf-denoise"]),
    ],
    targets: [
        .target(
            name: "NonlocalMatchFilter",
            path: "Sources/NonlocalMatchFilter"),
        .executableTarget(
            name: "nlmf-denoise",
            dependencies: ["NonlocalMatchFilter"],
            path: "Sources/nlmf-denoise"),
        .testTarget(
            name: "NonlocalMatchFilterTests",
            dependencies: ["NonlocalMatchFilter"],
            path: "Tests/NonlocalMatchFilterTests"),
    ]
)
