//
//  NLMFModelBundle432Tests.swift
//
//  §432 的 A⑤：模型必须走 `Bundle.module`，依赖必须是**远程 SwiftPM**。
//
//  这两条都不是「读一遍代码确认」能守住的：一处写错时功能会静默自报不可用（看起来像打包故障），
//  另一处写错时 `Vendor/` 会悄悄长出一个 63 MB 的副本，而「与 ansel 一致」的语义随之消失
//  —— ansel 之所以在 `Vendor/` 里是因为 GPL 不能链接，NLMF 是 MIT，必须链接。
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

    /// A⑤ —— `Package.swift` 里的 NLMF 是**远程 SwiftPM 依赖 + 资源**，不是 `Vendor/`。
    func testTheDependencyIsRemoteSwiftPMNotVendored() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"),
                                  encoding: .utf8)

        XCTAssertTrue(manifest.contains("https://github.com/chemharuka/nonlocal-matchfilter-swift.git"),
                      "依赖必须是远程 SwiftPM 包")
        XCTAssertTrue(manifest.contains(".product(name: \"NonlocalMatchFilter\""),
                      "target 必须链接 NonlocalMatchFilter 产品")
        XCTAssertTrue(manifest.contains("resources: [.copy(\"Denoise/Models\")]"),
                      "模型必须作为 target 资源随包（这样它才在 Bundle.module 里）")
        XCTAssertFalse(manifest.contains("Vendor/nonlocal"),
                       "MIT 依赖不许搬进 Vendor/：那是 GPL 的隔离方式，不是 MIT 的")
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
