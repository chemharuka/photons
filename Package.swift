// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Photons",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonsCore", targets: ["PhotonsCore"]),
        .library(name: "PhotonsExport", targets: ["PhotonsExport"]),
        .executable(name: "photonsctl", targets: ["photonsctl"]),
    ],
    targets: [
        // Kernels ship as *copied resources* and are compiled at runtime by Metal.framework.
        // SwiftPM has no dependable .metal build step here, and the Metal toolchain component is a
        // network download that has already failed on this machine (see the session-bus pitfalls).
        .target(name: "PhotonsCore", resources: [.copy("Kernels")]),
        .target(name: "PhotonsExport", dependencies: ["PhotonsCore"]),
        .executableTarget(name: "photonsctl", dependencies: ["PhotonsCore", "PhotonsExport"]),
        .testTarget(name: "PhotonsCoreTests", dependencies: ["PhotonsCore", "PhotonsExport"]),
    ],
    // M0 keeps Swift 5 language mode: CIRAWFilter/MTLTexture are not Sendable and
    // strict-concurrency churn would bury the acceptance harness we are building here.
    // Migrating per-module is a tracked task (docs/tasks/002).
    swiftLanguageModes: [.v5]
)
