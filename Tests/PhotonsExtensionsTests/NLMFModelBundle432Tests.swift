//
//  NLMFModelBundle432Tests.swift
//
//  §432 的 A⑤：模型必须走 `Bundle.module`，依赖必须是 **MIT**，形态可以是远程 SwiftPM
//  **或** in-repo 的 `Vendor/nonlocal-matchfilter-swift`（本地 path 依赖）。
//
//  这两条都不是「读一遍代码确认」能守住的：一处写错时功能会静默自报不可用（看起来像打包故障），
//  另一处写错时会把一个 copyleft 依赖混进来，而「与 ansel 一致」的语义随之消失
//  —— ansel 之所以只能做子进程是因为 GPL 不能链接，NLMF 是 MIT，必须能链接。
//
//  形态口径：2026-11-21 起 vendored 是允许的形态（见 `VENDORED.md`）；
//  无论远程还是 vendored，许可都必须是 MIT，且依赖目录里不许混进 GPL/LGPL/AGPL 文本。
//

import XCTest
@testable import PhotonsExtensions

final class NLMFModelBundle432Tests: XCTestCase {

    /// A⑤ —— 模型在**target bundle**里，`Bundle.main` 里找不到。
    ///
    /// 这不是「随便找得到就行」：`Bundle.main` 在测试宿主里是 xctest 的 bundle，它当然没有
    /// 我们的资源；真正要钉住的是**解析器走的是 `Bundle.module`**，所以显式传 `.main` 时应该
    /// 找不到，而默认参数（`nil` → `.module`）找得到。把 `.module` 改成 `.main` 时这条会红。
    func testTheModelResolvesThroughTheTargetBundleNotTheMainBundle() throws {
        let job = NLMFDenoiseJob()

        let throughTarget = try XCTUnwrap(job.resolvedModel(environment: [:]),
                                         "没找到模型；找过：\(job.searchedModelURLs(environment: [:]).map(\.path))")
        XCTAssertTrue(throughTarget.path.contains("Photons_PhotonsExtensions.bundle"),
                      "解析到 target bundle 之外：\(throughTarget.path)")

        let throughMain = job.resolvedModel(environment: [:], bundle: .main)
        XCTAssertNil(throughMain, "Bundle.main 里不该有模型：\(throughMain?.path ?? "nil")")
    }

    /// A⑤ —— `Package.swift` 里的 NLMF 是**远程 SwiftPM 或 in-repo path 依赖**，
    /// 两种形态都必须是 **MIT**，不是 copyleft。
    ///
    /// 形态不是重点（2026-11-21 起 vendored 是允许的），许可才是：这条用例读依赖自带的
    /// `LICENSE` / `Package.swift`，并拒绝依赖目录里的 GPL/LGPL/AGPL 文本。
    func testTheDependencyIsMITAndEitherRemoteOrVendored() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"),
                                  encoding: .utf8)

        XCTAssertTrue(manifest.contains(".product(name: \"NonlocalMatchFilter\""),
                      "target 必须链接 NonlocalMatchFilter 产品")
        XCTAssertTrue(manifest.contains("resources: [.copy(\"Denoise/Models\")]"),
                      "模型必须作为 target 资源随包（这样它才在 Bundle.module 里）")

        // 实际 manifest：形态与许可都要过。
        try assertDependencyIsMITAndEitherRemoteOrVendored(manifest: manifest, root: root)

        // 两种形态的分支都注入一遍：远程 URL 与本地 path 都必须被接受。
        try assertDependencyIsMITAndEitherRemoteOrVendored(
            manifest: ".package(url: \"\(Self.remoteURL)\", from: \"0.1.0\")",
            root: root)
        try assertDependencyIsMITAndEitherRemoteOrVendored(
            manifest: ".package(path: \"\(Self.vendoredPath)\")",
            root: root)
    }

    // MARK: - 依赖形态与许可

    private static let remoteURL = "https://github.com/chemharuka/nonlocal-matchfilter-swift.git"
    private static let vendoredPath = "Vendor/nonlocal-matchfilter-swift"

    /// 形态：远程 SwiftPM **或** `Vendor/nonlocal-matchfilter-swift` path 依赖，二者皆可。
    /// 许可：依赖目录在场时必须读到 MIT 文本，且不许混进 copyleft 许可证文本。
    private func assertDependencyIsMITAndEitherRemoteOrVendored(
        manifest: String,
        root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let isRemote = manifest.contains(Self.remoteURL)
        let isVendored = manifest.contains(".package(path: \"\(Self.vendoredPath)\")")
        XCTAssertTrue(isRemote || isVendored,
                      "依赖必须是远程 SwiftPM 包或 in-repo path 依赖（二者皆可）",
                      file: file, line: line)

        let fileManager = FileManager.default
        let dependencyDirectory = root.appendingPathComponent(Self.vendoredPath)
        let hasLocalCopy = fileManager.fileExists(atPath: dependencyDirectory.path)
        if isVendored {
            XCTAssertTrue(hasLocalCopy,
                          "manifest 声明了 path 依赖，但 \(Self.vendoredPath) 不存在",
                          file: file, line: line)
        }

        if hasLocalCopy {
            let packageURL = dependencyDirectory.appendingPathComponent("Package.swift")
            let licenseURL = dependencyDirectory.appendingPathComponent("LICENSE")
            XCTAssertTrue(fileManager.fileExists(atPath: packageURL.path),
                          "依赖的 Package.swift 必须在场：\(packageURL.path)",
                          file: file, line: line)
            XCTAssertTrue(fileManager.fileExists(atPath: licenseURL.path),
                          "依赖的 LICENSE 必须在场：\(licenseURL.path)",
                          file: file, line: line)

            let license = try String(contentsOf: licenseURL, encoding: .utf8)
            XCTAssertTrue(license.contains("MIT License")
                            || license.contains("Permission is hereby granted, free of charge"),
                          "依赖许可必须是 MIT：\(licenseURL.path)",
                          file: file, line: line)
            assertNoCopyleftLicenseText(in: dependencyDirectory, file: file, line: line)
        } else {
            // 远程形态没有本地副本可读，退回到 notices 里的许可声明。
            XCTAssertTrue(isRemote,
                          "既不是远程 SwiftPM 包，也没有本地副本可以核对许可",
                          file: file, line: line)
        }

        let noticesURL = root.appendingPathComponent("THIRD_PARTY_NOTICES.md")
        if fileManager.fileExists(atPath: noticesURL.path) {
            let notices = try String(contentsOf: noticesURL, encoding: .utf8)
            XCTAssertTrue(notices.lowercased().contains("nonlocal-matchfilter"),
                          "THIRD_PARTY_NOTICES.md 必须提到 nonlocal-matchfilter",
                          file: file, line: line)
            if !hasLocalCopy {
                XCTAssertTrue(notices.contains("MIT"),
                              "远程依赖没有本地副本，notices 必须声明其 MIT 许可",
                              file: file, line: line)
            }
        } else if !hasLocalCopy {
            XCTAssertTrue(isRemote,
                          "依赖既无本地副本也无 THIRD_PARTY_NOTICES.md，无法核对许可",
                          file: file, line: line)
        }
    }

    /// 依赖目录里只允许 MIT；任何 license/copying 文件含 GPL/LGPL/AGPL 标题都算红。
    private func assertNoCopyleftLicenseText(
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let licenseNames: Set<String> = [
            "license", "license.md", "license.txt",
            "licence", "licence.md", "licence.txt",
            "copying", "copying.md", "copying.txt",
            "copyright", "copyright.md", "copyright.txt",
        ]
        let copyleftMarkers = [
            "GNU General Public License",
            "GNU Lesser General Public License",
            "GNU Library General Public License",
            "GNU Affero General Public License",
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard licenseNames.contains(url.lastPathComponent.lowercased()) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for marker in copyleftMarkers {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(marker),
                               "依赖目录里混进了 copyleft 许可证文本（\(marker)）：\(url.path)",
                               file: file, line: line)
            }
        }
    }

    /// §0.4 —— 拷进来的模型是**完整**的那一份（63 MB 的 weights 在，不只是 Manifest）。
    func testTheBundledModelCarriesItsWeights() throws {
        let job = NLMFDenoiseJob()
        let model = try XCTUnwrap(job.resolvedModel(environment: [:]))
        let weights = model.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let manifest = model.appendingPathComponent("Manifest.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path), "缺 Manifest.json")
        let size = (try FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? 0
        XCTAssertEqual(size, 64_386_304,
                       "权重不是 63 MB 那一份（只拷了 Manifest 的话会是 0）")
    }

    // MARK: - A① 可用性只看模型在不在，hint 带完整路径

    /// A①（第一条）—— 模型就位时 `isAvailable` 为 true，且不需要任何可执行文件。
    /// 这正是 MIT 那条路的定义性质：没有工具要定位。
    func testIsAvailableIsTrueWhenTheModelIsInPlace() throws {
        let job = NLMFDenoiseJob()
        let resolved = try XCTUnwrap(job.resolvedModel(environment: [:]))

        XCTAssertTrue(job.isAvailable(environment: [:]))
        // 同一条路径显式给进来也必须为 true —— 两条解析分支说的是同一件事。
        XCTAssertTrue(NLMFDenoiseJob(modelURL: resolved).isAvailable(environment: [:]))
        // 环境变量指向它也可以（开发时换模型的口子）。
        XCTAssertTrue(job.isAvailable(environment: [NLMFDenoiseJob.environmentKey: resolved.path]))
    }

    /// A①（第二条）—— 模型缺失时 false，**且 `modelPathHint` 是完整期望路径**，
    /// 不是一句「缺模型」。
    func testIsAvailableIsFalseAndTheHintNamesTheFullExpectedPath() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-nlmf-\(UUID().uuidString).mlpackage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path), "前提：这个路径必须不存在")

        let job = NLMFDenoiseJob(modelURL: absent)
        XCTAssertFalse(job.isAvailable(environment: [:]))
        XCTAssertEqual(job.modelPathHint(), absent.path,
                       "tooltip 要指向真的去查的那个完整路径")

        // 不显式给路径时，hint 是随包那条**完整**路径（能从它直接找到 target bundle）。
        let bundled = try XCTUnwrap(NLMFDenoiseJob.expectedModelPath(variant: .t256))
        XCTAssertEqual(NLMFDenoiseJob().modelPathHint(), bundled.path)
        XCTAssertTrue(bundled.path.hasSuffix("Models/v_matmul_256.mlpackage"),
                      "路径必须点名模型文件本身：\(bundled.path)")
    }
}
