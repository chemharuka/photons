// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Photons",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonsCore", targets: ["PhotonsCore"]),
        .executable(name: "photonsctl", targets: ["photonsctl"]),
    ],
    targets: [
        .target(name: "PhotonsCore"),
        .executableTarget(name: "photonsctl", dependencies: ["PhotonsCore"]),
        .testTarget(name: "PhotonsCoreTests", dependencies: ["PhotonsCore"]),
    ],
    // M0 keeps Swift 5 language mode: CIRAWFilter/MTLTexture are not Sendable and
    // strict-concurrency churn would bury the acceptance harness we are building here.
    // Migrating per-module is a tracked task (docs/tasks/002).
    swiftLanguageModes: [.v5]
)
