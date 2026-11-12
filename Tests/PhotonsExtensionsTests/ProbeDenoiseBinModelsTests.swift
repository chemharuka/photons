import Foundation
import XCTest
@testable import PhotonsExtensions

/// 387 — 模型跟着 `ansel-denoise-swift` 走，打包进 **该模块自己的目录** `Contents/Resources/bin/models/`。
///
/// 口径（用户 2026-11-12）：「denoise-quarter-single-v1.anselnn 是打包进 ansel-denoise-swift 模块中」。
/// 这个布局不是审美问题：权重是那个 GPL-3.0 工具的数据，Photons 只把路径当参数传给它
/// （`batch <model> <input>`），从不自己读。放同一个目录，许可边界在 bundle 里一眼可见 ——
/// 顶层 `Contents/Resources/` 是 Photons 自己的，`Contents/Resources/bin/` 是 GPL 聚合体。
///
/// 这里钉住的是**查找顺序**，因为打包位置和解析顺序不一致时，打进去也找不到，
/// 而症状只是菜单灰掉（没有任何崩溃或日志）。
final class ProbeDenoiseBinModelsTests: XCTestCase {

    private let location = AnselDenoiseLocation(variant: .quarter)

    /// ① `bin/models/` 必须排在 bundle 顶层 `models/` 之前。
    func testTheBinModelsLocationIsSearchedBeforeTheTopLevel() throws {
        let searched = location.searchedModelURLs(environment: [:], bundle: Bundle(for: Self.self))
        print("PROBE order:")
        for (i, url) in searched.enumerated() { print("  [\(i)] \(url.path)") }

        let binIndex = try XCTUnwrap(
            searched.firstIndex { $0.path.contains("/bin/models/") },
            "找不到 bin/models 这一级；顺序是 \(searched.map(\.path))")
        let topIndex = try XCTUnwrap(
            searched.firstIndex { $0.path.contains("Resources/models/") && !$0.path.contains("/bin/") },
            "找不到顶层 Resources/models 这一级")
        XCTAssertLessThan(binIndex, topIndex,
                          "bin/models 必须排在顶层 models 之前（实际 \(binIndex) vs \(topIndex)）")
    }

    /// ② 环境变量仍然排第一（覆盖一切）。
    func testTheEnvironmentVariableStillWins() {
        let bogus = "/tmp/nope-\(UUID().uuidString).anselnn"
        let searched = location.searchedModelURLs(
            environment: [AnselDenoiseLocation.environmentKey: bogus],
            bundle: Bundle(for: Self.self))
        XCTAssertEqual(searched.first?.path, bogus)
    }

    /// ③ 这条验证**真实 bundle 布局**（打进 app 的那个）：模型确实躺在可执行文件旁边。
    ///    不走 `Bundle.main`（测试进程的 main 是 xctest），直接按约定的路径问磁盘。
    func testTheShippedModelSitsNextToTheExecutable() throws {
        // Tests run from the package root; the built app is under .build/.
        // `#filePath` is <root>/Tests/PhotonsExtensionsTests/<this file>, so the root is **three**
        // levels up (file → its dir → Tests → root). Getting this wrong once made the test skip
        // silently, which is the failure mode this whole test exists to catch.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PhotonsExtensionsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let resources = root.appendingPathComponent(".build/Photons.app/Contents/Resources")
        let bin = resources.appendingPathComponent("bin")
        let model = bin.appendingPathComponent("models/denoise-quarter-single-v1.anselnn")
        let tool = bin.appendingPathComponent("ansel-denoise-swift")

        // A fresh clone or a `swift test` without `make app` has no bundle: skip rather than fail,
        // but print so a green run cannot be mistaken for "the layout was checked".
        guard FileManager.default.fileExists(atPath: bin.path) else {
            print("PROBE 跳过：没有 \(bin.path)（先跑 make app 才有 bundle 可查）")
            throw XCTSkip("no built app bundle at \(bin.path)")
        }

        let fm = FileManager.default
        print("PROBE tool  exists=\(fm.fileExists(atPath: tool.path)) executable=\(fm.isExecutableFile(atPath: tool.path))")
        print("PROBE model exists=\(fm.fileExists(atPath: model.path)) bytes=\((try? Data(contentsOf: model).count) ?? -1)")
        XCTAssertTrue(fm.isExecutableFile(atPath: tool.path), "工具应可执行：\(tool.path)")
        XCTAssertTrue(fm.fileExists(atPath: model.path), "模型应与工具同目录：\(model.path)")

        // And the model must NOT be in Photons' own top-level Resources: that is the boundary.
        let topLevel = resources.appendingPathComponent("models/denoise-quarter-single-v1.anselnn")
        XCTAssertFalse(fm.fileExists(atPath: topLevel.path),
                       "模型不该在 Photons 自己的顶层 Resources/models 里：\(topLevel.path)")
    }
}
