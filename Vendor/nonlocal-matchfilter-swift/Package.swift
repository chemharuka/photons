// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The test target is declared only when its sources are present. Photons vendors this
// package as a build dependency and copies `Sources/` but not `Tests/`; SwiftPM rejects a
// target whose path is missing, so a manifest that always declared it would make the
// vendored copy unbuildable.
var targets: [Target] = [
    .target(
        name: "NonlocalMatchFilter",
        path: "Sources/NonlocalMatchFilter"),
    .executableTarget(
        name: "nlmf-denoise",
        dependencies: ["NonlocalMatchFilter"],
        path: "Sources/nlmf-denoise"),
]
if FileManager.default.fileExists(atPath: "Tests/NonlocalMatchFilterTests") {
    targets.append(.testTarget(
        name: "NonlocalMatchFilterTests",
        dependencies: ["NonlocalMatchFilter"],
        path: "Tests/NonlocalMatchFilterTests"))
}

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
    targets: targets
)
