// swift-tools-version: 6.0
import PackageDescription

// A **separate** package, so wiring HDR merge in adds no edits to Photons' own `Package.swift`,
// `photonsctl/main.swift`, menus or window code.
//
// It depends on the Photons package by path purely to reuse `PhotonsExtensions.HDRMergeService`
// (MIT, part of Photons). The extension module itself has **no** dependency on `PhotonsCore` or
// `PhotonsCatalog` — it is a plain file-in/file-out step, like the AI denoise extension.
//
// It must *not* be the other way round: `hdrmerge-swift` is GPLv3, and a GPL library linked into
// Photons code would drag Photons with it. Here the GPL program is only ever a child process.
//
//   cd Tools/PhotonsHDR && swift build -c release
//   .build/release/photons-hdr merge ~/Desktop/austria/L103066{4,5,6}.dng
//
let package = Package(
    name: "PhotonsHDR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "photons-hdr", targets: ["PhotonsHDR"]),
    ],
    dependencies: [
        .package(name: "Photons", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "PhotonsHDR",
            dependencies: [
                .product(name: "PhotonsExtensions", package: "Photons"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
