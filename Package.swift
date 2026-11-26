// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Photons",
    // 本地化：key 就是中文原文，`Sources/PhotonsLocalization/Resources/<lang>.lproj` 是唯一翻译面。
    // SwiftPM 要求带 `.lproj` 资源的包声明一个源语言 —— 中文是源语言，en 是译文。
    // 顺序由 SwiftPM 定：`defaultLocalization` 必须在 `platforms` 之前。
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        // 界面文案的唯一来源：中文原文即 key（`Loc.t("效果卡")`），en 表是译文。
        // 单独成 target 的理由是资源：`.lproj` 必须挂在一个 target 上才会被打进 `Bundle.module`，
        // 而 PhotonsCore/PhotonsUI/PhotonsApp 都要能读到同一张表。
        .library(name: "PhotonsLocalization", targets: ["PhotonsLocalization"]),
        .library(name: "PhotonsCore", targets: ["PhotonsCore"]),
        .library(name: "PhotonsExport", targets: ["PhotonsExport"]),
        .library(name: "PhotonsCatalog", targets: ["PhotonsCatalog"]),
        // Optional post-processing that writes a NEW file (AI denoise, HDR merge). No
        // dependency on PhotonsCore by design; see Sources/PhotonsExtensions/README.md.
        .library(name: "PhotonsExtensions", targets: ["PhotonsExtensions"]),
        // The UI shell lives in a library so its pure layout math and model are unit-testable;
        // `PhotonsApp` is the thin `@main` + `AppDelegate`/menu/bundle shim; a test target can depend on
        // a library, not on an executable, which is the other reason the shell lives here.
        .library(name: "PhotonsUI", targets: ["PhotonsUI"]),
        .executable(name: "photonsctl", targets: ["photonsctl"]),
        .executable(name: "Photons", targets: ["PhotonsApp"]),
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
        // Vendored copy of the MIT denoiser (see Vendor/nonlocal-matchfilter-swift/
        // VENDORED.md). In-repo so a checkout builds without a sibling clone, and
        // no version requirement: this library is not released yet.
        .package(path: "Vendor/nonlocal-matchfilter-swift"),
    ],
    targets: [
        // Kernels ship as *copied resources* and are compiled at runtime by Metal.framework.
        // SwiftPM has no dependable .metal build step here, and the Metal toolchain component is a
        // network download that has already failed on this machine (see the session-bus pitfalls).
        .target(name: "PhotonsLocalization", resources: [.process("Resources")]),
        .target(name: "PhotonsCore", dependencies: ["PhotonsLocalization"], resources: [.copy("Kernels")]),
        .target(name: "PhotonsExport", dependencies: ["PhotonsCore", "PhotonsLocalization"]),
        .target(name: "PhotonsExtensions", dependencies: ["PhotonsLocalization",
                                                          .product(name: "NonlocalMatchFilter",
                                                                   package: "nonlocal-matchfilter-swift")],
                resources: [.copy("Denoise/Models")]),
        .target(name: "PhotonsCatalog", dependencies: [
            "PhotonsCore", "PhotonsLocalization",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "photonsctl", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog",
                                                             "PhotonsLocalization"]),
        // `PhotonsExport` is here because the export sheet (M5) drives `BatchExporter` from the
        // window: the engine is the only implementation of "render + name + encode + report", and a
        // second copy inside the UI would be the beginning of two exports that disagree.
        //
        // `PhotonsExtensions` is here for §384: 「HDR 合成…」 in the right-click menu calls
        // `HDRMergeService` — the GPLv3 `hdrmerge-swift` binary is spawned as a child process by that
        // module, never linked, so this edge keeps Photons MIT.
        .target(name: "PhotonsUI", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog",
                                                  "PhotonsExtensions", "PhotonsLocalization"],
                resources: []),
        .executableTarget(name: "PhotonsApp", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsCatalog",
                                                             "PhotonsUI", "PhotonsLocalization"]),
        .testTarget(name: "PhotonsCoreTests", dependencies: ["PhotonsCore", "PhotonsExport", "PhotonsLocalization"]),
        .testTarget(name: "PhotonsExportTests", dependencies: ["PhotonsExport", "PhotonsCore"]),
        .testTarget(name: "PhotonsExtensionsTests", dependencies: ["PhotonsExtensions"]),
        .testTarget(name: "PhotonsCatalogTests", dependencies: ["PhotonsCatalog", "PhotonsCore"]),
        .testTarget(name: "PhotonsUITests", dependencies: ["PhotonsUI", "PhotonsCatalog", "PhotonsExtensions",
                                                            "PhotonsLocalization"]),
    ],
    // M0 keeps Swift 5 language mode: CIRAWFilter/MTLTexture are not Sendable and
    // strict-concurrency churn would bury the acceptance harness we are building here.
    // Moving a target to Swift 6 language mode happens one module at a time, once its CIRAWFilter /
    // MTLTexture surface is wrapped; no module has been migrated yet.
    swiftLanguageModes: [.v5]
)
