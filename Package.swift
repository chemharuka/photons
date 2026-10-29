// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Photons",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonsCore", targets: ["PhotonsCore"]),
        .library(name: "PhotonsExport", targets: ["PhotonsExport"]),
        // Depth Anything V2 Small (Core ML) — the depth map that feeds the dehaze assist and the depth
        // mask (task 120). Weights are Apache-2.0 and ship as a repo resource compiled by
        // `scripts/depth-model.sh`; this target is the only place that touches `MLModel`.
        .library(name: "PhotonsDepth", targets: ["PhotonsDepth"]),
        .library(name: "PhotonsCatalog", targets: ["PhotonsCatalog"]),
        // The UI shell lives in a library so its pure layout math and model are unit-testable;
        // `PhotonsApp` is the thin `@main` + `AppDelegate`/menu/bundle shim; a test target can depend on
        // a library, not on an executable, which is the other reason the shell lives here.
        .library(name: "PhotonsUI", targets: ["PhotonsUI"]),
        .executable(name: "photonsctl", targets: ["photonsctl"]),
        .executable(name: "Photons", targets: ["PhotonsApp"]),
    ],
    // The single third-party dependency: GRDB (MIT), an SQLite toolkit. Pinned on purpose —
    // the catalog needs WAL, a migration ladder and typed row decoding, and GRDB resolves to exactly
    // one package (it vendors its own SQLite). See THIRD_PARTY_NOTICES.md.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1")),
    ],
    targets: [
        // Kernels ship as *copied resources* and are compiled at runtime by Metal.framework.
        // SwiftPM has no dependable .metal build step here, and the Metal toolchain component is a
        // network download that has already failed on this machine (see the session-bus pitfalls).
        .target(name: "PhotonsCore", resources: [.copy("Kernels")]),
        .target(name: "PhotonsExport", dependencies: ["PhotonsCore"]),
        .target(name: "PhotonsDepth", dependencies: ["PhotonsCore"]),
        .target(name: "PhotonsCatalog", dependencies: [
            "PhotonsCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "photonsctl", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog", "PhotonsDepth"]),
        // `PhotonsExport` is here because the export sheet (M5) drives `BatchExporter` from the
        // window: the engine is the only implementation of "render + name + encode + report", and a
        // second copy inside the UI would be the beginning of two exports that disagree.
        .target(name: "PhotonsUI", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog"],
                resources: []),
        .executableTarget(name: "PhotonsApp", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog", "PhotonsUI"]),
        .testTarget(name: "PhotonsCoreTests", dependencies: ["PhotonsCore", "PhotonsExport"]),
        .testTarget(name: "PhotonsExportTests", dependencies: ["PhotonsExport", "PhotonsCore"]),
        .testTarget(name: "PhotonsCatalogTests", dependencies: ["PhotonsCatalog", "PhotonsCore"]),
        .testTarget(name: "PhotonsUITests", dependencies: ["PhotonsUI", "PhotonsCatalog"]),
        .testTarget(name: "PhotonsDepthTests", dependencies: ["PhotonsDepth", "PhotonsCore"]),
    ],
    // M0 keeps Swift 5 language mode: CIRAWFilter/MTLTexture are not Sendable and
    // strict-concurrency churn would bury the acceptance harness we are building here.
    // Moving a target to Swift 6 language mode happens one module at a time, once its CIRAWFilter /
    // MTLTexture surface is wrapped; no module has been migrated yet.
    swiftLanguageModes: [.v5]
)
