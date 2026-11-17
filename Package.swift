// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Photons",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "PhotonsCore", targets: ["PhotonsCore"]),
        .library(name: "PhotonsFileAccess", targets: ["PhotonsFileAccess"]),
        .library(name: "PhotonsExport", targets: ["PhotonsExport"]),
        .library(name: "PhotonsCatalog", targets: ["PhotonsCatalog"]),
        // Optional post-processing that writes a NEW file (AI denoise, HDR merge). No
        // dependency on PhotonsCore by design; see Sources/PhotonsExtensions/README.md.
        .library(name: "PhotonsExtensions", targets: ["PhotonsExtensions"]),
        .library(name: "PhotonsPanorama", targets: ["PhotonsPanorama"]),
        // The UI shell lives in a library so its pure layout math and model are unit-testable;
        // `PhotonsApp` is the thin `@main` + `AppDelegate`/menu/bundle shim; a test target can depend on
        // a library, not on an executable, which is the other reason the shell lives here.
        .library(name: "PhotonsUI", targets: ["PhotonsUI"]),
        .library(name: "PhotonsMobile", targets: ["PhotonsMobile"]),
        .executable(name: "photonsctl", targets: ["photonsctl"]),
        .executable(name: "Photons", targets: ["PhotonsApp"]),
        .executable(name: "photons-panorama-worker", targets:["PhotonsPanoramaWorker"]),
    ],
    // Two third-party dependencies, both MIT.
    //
    // GRDB (SQLite toolkit) is pinned on purpose — the catalog needs WAL, a migration
    // ladder and typed row decoding, and GRDB resolves to exactly one package (it
    // vendors its own SQLite). See THIRD_PARTY_NOTICES.md.
    //
    // NonlocalMatchFilter is our own Core ML port of the nonlocal match-filter RAW
    // denoiser (arXiv:2604.17453). It is MIT, so unlike the GPL ansel tool it links
    // **in-process** — no subprocess, no JSON envelope, no second DNG reader. The
    // weights are ~63 MB and ship inside the app bundle.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.11.1")),
        .package(url: "https://github.com/chemharuka/nonlocal-matchfilter-swift.git",
                 .upToNextMinor(from: "1.0.0")),
    ],
    targets: [
        // Kernels ship as *copied resources* and are compiled at runtime by Metal.framework.
        // SwiftPM has no dependable .metal build step here, and the Metal toolchain component is a
        // network download that has already failed on this machine (see the session-bus pitfalls).
        .target(name: "PhotonsLocalization",resources:[.process("Resources")]),
        .target(name: "PhotonsImageCodecs"),
        .target(name: "PhotonsCore", dependencies:["PhotonsLocalization", "PhotonsImageCodecs"], resources: [.copy("Kernels")]),
        .target(name: "PhotonsExport", dependencies: ["PhotonsCore","PhotonsLocalization","PhotonsPanorama"]),
        .target(name: "PhotonsFileAccess"),
        .target(name: "PhotonsJobs", dependencies:["PhotonsPanorama","PhotonsExport","PhotonsFileAccess","PhotonsLocalization"]),
        .executableTarget(name:"PhotonsPanoramaWorker", dependencies:["PhotonsJobs","PhotonsLocalization"]),
        .target(name: "PhotonsExtensions", dependencies: ["PhotonsFileAccess","PhotonsLocalization","PhotonsImageCodecs",
                                                          .product(name: "NonlocalMatchFilter",
                                                                   package: "nonlocal-matchfilter-swift")],
                resources: [.copy("Denoise/Models")]),
        .target(name: "PhotonsPanorama", dependencies: ["PhotonsCore", "PhotonsExtensions", "PhotonsFileAccess", "PhotonsLocalization"], resources: [.copy("Profiles")]),
        .target(name: "PhotonsCatalog", dependencies: ["PhotonsLocalization",
            "PhotonsCore",
            "PhotonsFileAccess",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "photonsctl", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog"]),
        .target(name: "PhotonsMobile", dependencies: ["PhotonsCore", "PhotonsCatalog", "PhotonsPanorama", "PhotonsExport", "PhotonsJobs", "PhotonsFileAccess", "PhotonsLocalization"]),
        // `PhotonsExport` is here because the export sheet (M5) drives `BatchExporter` from the
        // window: the engine is the only implementation of "render + name + encode + report", and a
        // second copy inside the UI would be the beginning of two exports that disagree.
        //
        // `PhotonsExtensions` is here for §384: 「HDR 合成…」 in the right-click menu calls
        // `HDRMergeService` — the GPLv3 `hdrmerge-swift` binary is spawned as a child process by that
        // module, never linked, so this edge keeps Photons MIT.
        .target(name: "PhotonsUI", dependencies: ["PhotonsLocalization","PhotonsCore", "PhotonsExport", "PhotonsCatalog",
                                                  "PhotonsExtensions", "PhotonsPanorama", "PhotonsFileAccess", "PhotonsJobs"],
                resources: []),
        .executableTarget(name: "PhotonsApp", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog", "PhotonsUI", "PhotonsFileAccess"]),
        .testTarget(name: "PhotonsJobsTests", dependencies: ["PhotonsJobs"]),
        .testTarget(name: "PhotonsFileAccessTests", dependencies: ["PhotonsFileAccess"]),
        .testTarget(name: "PhotonsCoreTests", dependencies: ["PhotonsCore", "PhotonsExport"]),
        .testTarget(name: "PhotonsExportTests", dependencies: ["PhotonsExport", "PhotonsCore"]),
        .testTarget(name: "PhotonsExtensionsTests", dependencies: ["PhotonsExtensions"]),
        .testTarget(name: "PhotonsPanoramaTests", dependencies: ["PhotonsPanorama"]),
        .testTarget(name: "PhotonsCatalogTests", dependencies: ["PhotonsCatalog", "PhotonsCore"]),
        .testTarget(name: "PhotonsUITests", dependencies: ["PhotonsUI", "PhotonsCatalog", "PhotonsExtensions"]),
    ],
    // M0 keeps Swift 5 language mode: CIRAWFilter/MTLTexture are not Sendable and
    // strict-concurrency churn would bury the acceptance harness we are building here.
    // Moving a target to Swift 6 language mode happens one module at a time, once its CIRAWFilter /
    // MTLTexture surface is wrapped; no module has been migrated yet.
    swiftLanguageModes: [.v5]
)
