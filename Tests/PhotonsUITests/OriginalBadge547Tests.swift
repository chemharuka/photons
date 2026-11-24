import XCTest
import AppKit
import PhotonsLocalization
@testable import PhotonsUI

/// 547 — 变换模式 blocks 「显示原图」 (both `\` and the menu row), and while the decode *is* on screen the
/// status readout grows a `修改前` line directly under `显示器信息`, in the same type.
///
/// The two claims are one fixture because they share the canvas and the readout: entering 变换 while
/// the decode is up has to leave it, and the badge has to be the chip's second row rather than a
/// second style. Every assertion reads the **real** controls the app lays out.
@MainActor
final class OriginalBadge547Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-547-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func showOriginalMenuItem() -> NSMenuItem {
        NSMenuItem(title: Loc.t("显示原图"),
                   action: #selector(EditorWindowController.toggleShowOriginalAction(_:)),
                   keyEquivalent: "\\")
    }

    // MARK: - ① 变换模式挡住 `\` 与菜单行

    func testTransformModeBlocksShowOriginalUntilTheToolCloses() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        let item = showOriginalMenuItem()

        // Outside 变换 the door is open.
        XCTAssertTrue(loupe.setShowOriginal(true))
        XCTAssertTrue(loupe.showOriginal)
        XCTAssertTrue(editor.validateMenuItem(item), "menu row must be enabled outside 变换")

        // Entering 变换 while the decode is up leaves it first — the user's 「若已在显示原图，则先
        // 退出再进变换模式」.
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "变换 mode did not open")
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(loupe.showOriginal, "entering 变换 must leave 显示原图")
        XCTAssertFalse(editor.validateMenuItem(item), "the 显示原图 row must be disabled in 变换")

        // `\` (the toggle the menu item and the key both reach) is refused.
        XCTAssertFalse(loupe.toggleShowOriginal(), "`\\` must not enter 显示原图 in 变换")
        XCTAssertFalse(loupe.showOriginal)
        XCTAssertFalse(editor.validateMenuItem(item))

        // The state setter is the same door and is refused too.
        XCTAssertFalse(loupe.setShowOriginal(true))
        XCTAssertFalse(loupe.showOriginal)

        // Leaving 变换 reopens the door on the same window.
        loupe.cancelCropTool()
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(loupe.isTransformModeActive)
        XCTAssertTrue(loupe.toggleShowOriginal(), "`\\` must work again after 变换 closes")
        XCTAssertTrue(loupe.showOriginal)
        XCTAssertTrue(editor.validateMenuItem(item))
    }

    // MARK: - ② / ③ 标示在下方，样式与「显示器信息」同源

    func testBadgeSitsUnderTheDisplayLineWithTheSameStyle() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let chip = loupe.statusChipForTesting
        let info = chip.infoLabel
        let badge = chip.originalLabel

        // Off: the row is hidden, not an empty string.
        XCTAssertFalse(loupe.showOriginal)
        XCTAssertTrue(badge.isHidden)
        XCTAssertEqual(badge.stringValue, Loc.t("修改前"),
                       "hiding the badge must not blank its text")

        XCTAssertTrue(loupe.setShowOriginal(true))
        CropUITestSupport.pump(0.02)
        loupe.view.layoutSubtreeIfNeeded()
        chip.layout(in: loupe.view.bounds)

        XCTAssertFalse(badge.isHidden, "showOriginal = true must show the 修改前 row")
        XCTAssertEqual(badge.stringValue, Loc.t("修改前"))
        XCTAssertTrue(badge.isDescendant(of: chip),
                      "the badge must live in the same status chip as 显示器信息")
        XCTAssertEqual(info.superview, badge.superview)

        // ② the badge is the next row down. The chip is flipped (top edge is y = 0), so "below" is
        // `badge.minY >= info.maxY`, and the gap is the one line-spacing constant.
        XCTAssertGreaterThanOrEqual(badge.frame.minY, info.frame.maxY,
                                    "修改前 must be below 显示器信息: info \(info.frame) badge \(badge.frame)")
        XCTAssertEqual(badge.frame.minY - info.frame.maxY,
                       WorkspaceLayout.statusChipLineSpacing, accuracy: 0.001)
        XCTAssertEqual(WorkspaceLayout.statusChipLineSpacing, 2, accuracy: 0.001,
                       "the row gap is the pinned 2 pt")

        // ③ one factory: the two real controls agree on every style field, and the values are the
        // 显示器信息 line's own — not a second literal.
        XCTAssertEqual(badge.font, info.font)
        XCTAssertEqual(badge.font?.pointSize, info.font?.pointSize)
        XCTAssertEqual(badge.font?.pointSize, 10.5)
        XCTAssertEqual(badge.textColor, info.textColor)
        XCTAssertEqual(badge.alignment, info.alignment)

        // Off again: the row disappears (hidden control), and the chip keeps the same info line.
        XCTAssertFalse(loupe.setShowOriginal(false))
        XCTAssertTrue(badge.isHidden)
        XCTAssertEqual(badge.stringValue, Loc.t("修改前"))
        XCTAssertFalse(info.isHidden)
    }
}
