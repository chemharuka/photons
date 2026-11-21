import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 472 — 胶片条竖拍照片按 **1:1** 显示：边长取有效高度（整格高 − caption），水平居中；
/// 横拍/未知朝向仍是整格宽。判定与网格同源（`AssetPortrait`），所以裁切成竖拍的文档也算竖拍。
///
/// The numbers are read off `FilmstripCard.thumbRectForTesting`, the same rect `layout()`, `draw()`
/// and the overlay use, never re-derived from the formula.
final class FilmstripPortrait472Tests: XCTestCase {

    /// The shipped filmstrip cell: 90 × 72 with a 12 pt caption ⇒ a 90 × 60 picture area.
    private let cellSize = CGSize(width: 90, height: 72)

    private func asset(id: String = "A", width: Int?, height: Int?,
                       develop: String = "{}") -> Asset {
        Asset(id: id, sourceRootId: "root", relPath: "a.dng", filename: "a.dng", ext: "dng",
              kind: .raw, size: 1024, mtime: 0, contentHash: "abc-\(id)",
              width: width, height: height, captureLocalDate: "2026-11-19 10:00",
              rating: 0, flag: nil, colorLabel: nil, cameraModel: "NIKON Z 8",
              developJson: develop)
    }

    private func card(_ asset: Asset) -> FilmstripCard {
        let view = FilmstripCard()
        view.frame = NSRect(origin: .zero, size: cellSize)
        view.asset = asset
        return view
    }

    private func effectiveHeight(_ view: FilmstripCard) -> CGFloat {
        max(1, view.bounds.height - WorkspaceLayout.filmstripCaptionHeight)
    }

    /// A 3:4 portrait crop centred in a 3:2 landscape frame.
    private func portraitCropJSON() throws -> String {
        var edit = EditModel()
        let width = (3.0 / 4.0) / (3.0 / 2.0)      // 0.5 of the landscape width
        let left = (1 - width) / 2
        edit.geometry.cropRect = CropRect(left: left, top: 0, right: left + width, bottom: 1)
        return try Catalog.encode(edit)
    }

    // MARK: - ① 竖拍：1:1，水平居中，高度不变

    func testPortraitThumbIsSquareCentredAndKeepsTheFullHeight() {
        let view = card(asset(width: 40, height: 60))
        let rect = view.thumbRectForTesting
        let h = effectiveHeight(view)
        print("472 ① portrait thumb \(rect) bounds \(view.bounds) caption "
              + "\(WorkspaceLayout.filmstripCaptionHeight)")

        XCTAssertEqual(rect.width, rect.height, accuracy: 1, "竖拍 1:1")
        XCTAssertEqual(rect.height, h, accuracy: 0.001, "高度 = 整格高 − caption，不变")
        XCTAssertEqual(rect.minY, 0)
        let leftGap = rect.minX
        let rightGap = view.bounds.width - rect.maxX
        XCTAssertLessThanOrEqual(abs(leftGap - rightGap), 1,
                                 "水平居中：左 \(leftGap) / 右 \(rightGap)")

        // layout() hands the same box to the thumbnail surface (the layer that shows the crop).
        view.layout()
        let thumb = view.subviews.first { $0.className.contains("Thumbnail") }
        XCTAssertEqual(thumb?.frame, rect, "缩略图层与 thumbRect 同框")
    }

    // MARK: - ② 横拍：整格宽，逐字段不变

    func testLandscapeThumbIsTheWholeCellWidthFieldForField() {
        let view = card(asset(width: 6000, height: 4000))
        let rect = view.thumbRectForTesting
        let h = effectiveHeight(view)
        print("472 ② landscape thumb \(rect) bounds \(view.bounds)")
        XCTAssertEqual(rect.origin.x, 0, "x")
        XCTAssertEqual(rect.origin.y, 0, "y")
        XCTAssertEqual(rect.size.width, view.bounds.width, "width")
        XCTAssertEqual(rect.size.height, h, "height = bounds.height − caption")
        XCTAssertEqual(rect, NSRect(x: 0, y: 0, width: view.bounds.width, height: h))
    }

    // MARK: - ③ 未知朝向 = 横拍（与网格同一条规则）

    func testUnknownOrientationStaysLandscape() {
        let view = card(asset(width: nil, height: nil))
        let rect = view.thumbRectForTesting
        print("472 ③ unknown thumb \(rect) bounds \(view.bounds)")
        XCTAssertEqual(rect, NSRect(x: 0, y: 0, width: view.bounds.width,
                                    height: effectiveHeight(view)))
        XCTAssertFalse(AssetPortrait.isPortrait(asset(width: nil, height: nil)))
    }

    // MARK: - ④ 横拍源 + crop 输出竖排 ⇒ 竖拍 1:1（读文档输出，不是记录）

    func testPortraitCropOfALandscapeRecordIsSquare() throws {
        let cropped = asset(width: 6000, height: 4000, develop: try portraitCropJSON())
        XCTAssertTrue(AssetPortrait.isPortrait(cropped), "裁切输出竖排，文档说了算")
        let view = card(cropped)
        let rect = view.thumbRectForTesting
        let h = effectiveHeight(view)
        print("472 ④ cropped portrait thumb \(rect) bounds \(view.bounds)")
        XCTAssertEqual(rect.width, rect.height, accuracy: 1, "裁切成竖拍 → 1:1")
        XCTAssertEqual(rect.height, h, accuracy: 0.001)
        let leftGap = rect.minX
        let rightGap = view.bounds.width - rect.maxX
        XCTAssertLessThanOrEqual(abs(leftGap - rightGap), 1, "水平居中")
    }
}
