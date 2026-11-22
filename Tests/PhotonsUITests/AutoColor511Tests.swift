import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 511 — §3.2.3 的「已达目标 ⇒ 不写文档（历史行数不变）」，用真会话 + 真渲染量一次。
///
/// 核心测（`AutoColor511Tests.testAtTargetIsZeroAndEmpty`）已经证明 `plan2D` 返回 0 + 0；
/// 这里补上「0 + 0 不铸历史行」的接线证据。把两个滑块放在自动上限**之上**是最强的构造：
/// 511 的结果是 `max(floor, lift)` 且 lift ≤ 8，没有一个合法的 raise，所以 `autoColor()` 必须
/// 返回 nil、文档逐位不变、`history.count` 不动。
@MainActor
final class AutoColor511Tests: XCTestCase {

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeController(url: URL, identity: String,
                                session: CatalogSession) throws -> LoupeController {
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)
        return loupe
    }

    func testAlreadyAtTheAutomaticCeilingDoesNotWriteAHistoryRow() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "511-at-target", session: session)

        session.applyEdit {
            $0.color.vibrance = AutoColor.maxVibrance
            $0.color.saturation = AutoColor.maxSaturation
        }
        XCTAssertTrue(session.commitEdit(label: "已饱和"))
        let before = session.edit
        let history = session.history.count

        XCTAssertNil(loupe.autoColor(), "自动上限之上 ⇒ 0 + 0，不写")
        XCTAssertEqual(session.edit, before, "文档逐位不变")
        XCTAssertEqual(session.history.count, history, "历史行数不变")
        XCTAssertEqual(loupe.lastAutoColorNoOpReasonForTesting, .alreadySaturated)
    }
}
