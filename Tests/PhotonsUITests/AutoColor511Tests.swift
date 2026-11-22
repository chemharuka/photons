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

    /// **518** — a document the owner has already pushed **above** the automatic ceiling survives
    /// 全部自动: `vibrance = 80` / `saturation = 40` may stay put or rise, never fall back to 60 / 25.
    ///
    /// The plan is recomputed from the metrics the controller actually measured instead of reading
    /// `lastAutoColorPlanForTesting`: that property is deliberately overwritten with the values
    /// **written**, and `colorCandidate`'s own `max(source, plan)` loop already floors them, which
    /// would mask a floor clamped inside `plan2D`. This is the seam where 511's ceiling-clamped floor
    /// is observable — with it restored, the plan reads `vibrance = 60`.
    func testDocumentAboveTheCeilingIsNotLoweredByAutoAll() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "518-above-ceiling", session: session)

        session.applyEdit {
            $0.color.vibrance = 80
            $0.color.saturation = 40
        }
        XCTAssertTrue(session.commitEdit(label: "手动调到上限之上"))
        let before = session.edit
        let historyBefore = session.history.count

        _ = loupe.autoAll()
        if loupe.lastAutoColorPlanForTesting == nil { _ = loupe.autoDevelop() }

        let metrics = try XCTUnwrap(loupe.lastAutoColorMetricsForTesting,
                                    "自动颜色必须真的量了一次")
        let plan = AutoColor.plan2D(metrics,
                                    currentVibrance: 80, currentSaturation: 40,
                                    floorVibrance: 80, floorSaturation: 40)
        print(String(format: "518 UI · plan v %.0f s %.0f · doc v %.0f s %.0f · passes %d",
                     plan.vibrance, plan.saturation,
                     session.edit.color.vibrance, session.edit.color.saturation,
                     loupe.lastAutoCompositePassCountForTesting))
        XCTAssertGreaterThanOrEqual(plan.vibrance, 80, "plan 的地板不许被 maxVibrance 60 夹掉")
        XCTAssertGreaterThanOrEqual(plan.saturation, 40, "plan 的地板不许被 maxSaturation 25 夹掉")
        XCTAssertGreaterThanOrEqual(session.edit.color.vibrance, 80, "写回后 vibrance 不许下调")
        XCTAssertGreaterThanOrEqual(session.edit.color.saturation, 40, "写回后 saturation 不许下调")

        if session.history.count > historyBefore {
            let row = try XCTUnwrap(session.history.snapshots.last, "新增的历史行必须可读")
            XCTAssertGreaterThanOrEqual(row.edit.color.vibrance, before.color.vibrance,
                                        "历史行里的 vibrance 不许下调")
            XCTAssertGreaterThanOrEqual(row.edit.color.saturation, before.color.saturation,
                                        "历史行里的 saturation 不许下调")
        } else {
            XCTAssertEqual(session.edit, before, "没有历史行 ⇒ 文档逐位不变，而不是下降")
        }
    }
}
