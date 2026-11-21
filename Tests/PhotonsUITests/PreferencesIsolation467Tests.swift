import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 467 —— **测试不许覆盖用户设置**的门。
///
/// 背景：偏好（筛选条、排序、最近库、画布、色标门限、裁切比例…）原来一律写 `UserDefaults.standard`。
/// `swift test` 跑在 `com.apple.dt.xctest.tool` 这个全机共享的域里，`--ui-smoke` 更是直接跑打包好的
/// app 本体（用户域 `com.nousresearch.photons`）—— 于是「跑一遍测试/烟测，用户的照片筛选就变了」。
///
/// 现在所有默认真实入口都解析到 `AppPreferences.store`：测试进程里它是**每进程一个**的隔离 suite。
/// 这个文件是三件事的证据：
///
///   ① 默认 store 不是用户的那份，而且是用完就删的隔离域；
///   ② 走**默认参数**写一遍（不注入任何 store），真实域一个 `photons.*` 键都不动，值却在隔离 store 里；
///   ③ 结构守卫：`Sources/` 里除白名单外**不许再出现** `UserDefaults.standard` 的代码用法
///      （注释不算）—— 谁把默认值写回去，这条就红。
final class PreferencesIsolation467Tests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/PhotonsUITests/PreferencesIsolation467Tests.swift
            .deletingLastPathComponent()          // …/Tests/PhotonsUITests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // 仓库根
    }

    /// The one file allowed to name the real domain in code (plus the smoke harness, which reads it
    /// to put back whatever a killed run may have left).
    private static let realDomainAllowlist = [
        "Sources/PhotonsLocalization/AppPreferences.swift",
        "Sources/PhotonsUI/UISmokeRunner.swift",
    ]

    private func realDomainPhotonsKeys() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("photons.") }
    }

    // MARK: ①

    func testTheDefaultStoreIsNotTheRealDomainInATestProcess() {
        XCTAssertTrue(AppPreferences.isRunningTests, "测试进程里必须认得出自己")
        XCTAssertFalse(AppPreferences.store === UserDefaults.standard,
                       "默认 store 就是 UserDefaults.standard —— 测试会写进用户的域")
        let name = AppPreferences.isolatedSuiteName ?? ""
        XCTAssertTrue(name.hasPrefix(AppPreferences.testsSuitePrefix),
                      "隔离域应当带前缀 \(AppPreferences.testsSuitePrefix)，实际「\(name)」")
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().keys.contains(name))
        print("① 默认 store = \(name) · 不是 \(UserDefaults.standard)")
    }

    // MARK: ②

    /// 默认参数 = 真实调用的那条路。这里一次也不传 store。
    func testWritingThroughTheDefaultedEntryPointsLeavesTheRealDomainAlone() throws {
        let before = realDomainPhotonsKeys()
        let library = "/tmp/photons-467-\(UUID().uuidString).photonslibrary"
        let filter = CatalogFilter(slots: [FilterSlot(dimension: .iso, values: ["3200"])])

        FilterPersistence.save(filter, libraryPath: library)
        RecentLibrary.remember(URL(fileURLWithPath: library))
        CropToolBar.lastCustomRatioText = "7:5"
        CanvasBackdrop.set(.light)
        HighlightCeiling.setEV(3.1)

        let after = realDomainPhotonsKeys()
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "默认入口往真实域里加了键")
        XCTAssertTrue(NSDictionary(dictionary: after).isEqual(to: before),
                      "默认入口改动了真实域的值：\(before) → \(after)")

        // 反向门：值必须真的落进隔离 store，否则上面那两条只是「什么都没写」。
        XCTAssertNotNil(FilterPersistence.load(libraryPath: library), "筛选没写进隔离 store")
        XCTAssertEqual(RecentLibrary.recall()?.path, library, "最近库没写进隔离 store")
        XCTAssertEqual(CropToolBar.lastCustomRatioText, "7:5", "裁切比例没写进隔离 store")
        XCTAssertEqual(CanvasBackdrop.current, .light, "画布没写进隔离 store")
        XCTAssertEqual(HighlightCeiling.currentEV, 3.1, accuracy: 1e-9, "色标门限没写进隔离 store")
        print("② 五个默认入口全部落在隔离 store，真实域键数 \(after.count) 不变")
    }

    // MARK: ③

    func testNoSourceFileOutsideTheAllowlistTouchesTheRealDomain() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        var offenders: [String] = []
        for file in files {
            let rel = file.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            if Self.realDomainAllowlist.contains(rel) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }          // 注释里写它是在解释这套东西
                if code.contains("UserDefaults.standard") {
                    offenders.append("\(rel):\(i + 1)  \(code)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件还在直接用 UserDefaults.standard（改走 AppPreferences.store）：\n"
                      + offenders.joined(separator: "\n"))
        print("③ Sources/ 共 \(files.count) 个 swift 文件，白名单外 \(offenders.count) 处 UserDefaults.standard")
    }
}
