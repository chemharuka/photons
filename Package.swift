// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Photons",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonsCore", targets: ["PhotonsCore"]),
        .library(name: "PhotonsExport", targets: ["PhotonsExport"]),
        .library(name: "PhotonsCatalog", targets: ["PhotonsCatalog"]),
        // The UI shell lives in a library so its pure layout math and model are unit-testable;
        // `PhotonsApp` is the thin `@main` + menu/bundle shim (docs/tasks/004-ui-skeleton.md §2b).
        .library(name: "PhotonsUI", targets: ["PhotonsUI"]),
        .executable(name: "photonsctl", targets: ["photonsctl"]),
        .executable(name: "Photons", targets: ["PhotonsApp"]),
    ],
    // The single third-party dependency: GRDB (MIT), an SQLite toolkit. Pinned on purpose —
    // see docs/tasks/003-catalog.md §1 and THIRD_PARTY_NOTICES.md.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1")),
    ],
    targets: [
        // Kernels ship as *copied resources* and are compiled at runtime by Metal.framework.
        // SwiftPM has no dependable .metal build step here, and the Metal toolchain component is a
        // network download that has already failed on this machine (see the session-bus pitfalls).
        .target(name: "PhotonsCore", resources: [.copy("Kernels")]),
        .target(name: "PhotonsExport", dependencies: ["PhotonsCore"]),
        .target(name: "PhotonsCatalog", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "photonsctl", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog"]),
        .target(name: "PhotonsUI", dependencies: ["PhotonsCore", "PhotonsCatalog"], resources: []),
        .executableTarget(name: "PhotonsApp", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog", "PhotonsUI"]),
        .testTarget(name: "PhotonsCoreTests", dependencies: ["PhotonsCore", "PhotonsExport"]),
        .testTarget(name: "PhotonsCatalogTests", dependencies: ["PhotonsCatalog"]),
        .testTarget(name: "PhotonsUITests", dependencies: ["PhotonsUI"]),
    ],
    // M0 keeps Swift 5 language mode: CIRAWFilter/MTLTexture are not Sendable and
    // strict-concurrency churn would bury the acceptance harness we are building here.
    // Migrating per-module is a tracked task (docs/tasks/002).
    swiftLanguageModes: [.v5]
)
