import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 436 A⑤/A⑦ — the swatch follows the **document's output pixels**, over a row that already holds
/// display pixels: a landscape record plus a portrait crop is a portrait cell.
final class GridPortrait436Tests: XCTestCase {

    private func asset(id: String = "A", width: Int?, height: Int?,
                       develop: String = "{}") -> Asset {
        Asset(id: id, sourceRootId: "root", relPath: "a.dng", filename: "a.dng", ext: "dng",
              kind: .raw, size: 1024, mtime: 0, contentHash: "abc-\(id)",
              width: width, height: height, captureLocalDate: "2026-11-19 10:00",
              rating: 0, flag: nil, colorLabel: nil, cameraModel: "NIKON Z 8",
              developJson: develop)
    }

    private func card(_ asset: Asset, size: CGSize = CGSize(width: 150, height: 133.1)) -> AssetCardView {
        let view = AssetCardView()
        view.frame = NSRect(origin: .zero, size: size)
        view.asset = asset
        paint(view)
        return view
    }

    private func paint(_ view: NSView) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        view.layout()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        for subview in view.subviews where !subview.isHidden { subview.draw(subview.bounds) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A 3:4 portrait crop centred in a 3:2 landscape frame.
    private func portraitCropJSON() throws -> String {
        var edit = EditModel()
        let width = (3.0 / 4.0) / (3.0 / 2.0)      // 0.5 of the landscape width
        let left = (1 - width) / 2
        edit.geometry.cropRect = CropRect(left: left, top: 0, right: left + width, bottom: 1)
        return try Catalog.encode(edit)
    }

    // MARK: - A⑤ the three states

    func testUprightRecordWithoutCropIsNarrow() {
        let view = card(asset(width: 6336, height: 9520))
        let rect = view.lastSwatchRect
        print("436 A⑤① record 6336×9520 → swatch \(rect)")
        XCTAssertEqual(rect, NSRect(x: 34, y: 0, width: 83, height: 111.1))
        XCTAssertEqual(rect.width / rect.height, 0.7471, accuracy: 0.001)
        XCTAssertTrue(AssetCardView.isPortrait(asset(width: 6336, height: 9520)))
    }

    func testLandscapeRecordWithPortraitCropIsNarrow() throws {
        let develop = try portraitCropJSON()
        let doc = asset(width: 9520, height: 6336, develop: develop)
        let view = card(doc)
        let rect = view.lastSwatchRect
        print("436 A⑤② record 9520×6336 + 3:4 crop → swatch \(rect)")
        XCTAssertTrue(AssetCardView.isPortrait(doc), "the crop, not the record, decides")
        XCTAssertEqual(rect, NSRect(x: 34, y: 0, width: 83, height: 111.1))
    }

    func testLandscapeRecordWithoutCropStaysFullWidth() {
        let doc = asset(width: 9520, height: 6336)
        let view = card(doc)
        let rect = view.lastSwatchRect
        print("436 A⑤③ record 9520×6336 → swatch \(rect)")
        XCTAssertFalse(AssetCardView.isPortrait(doc))
        XCTAssertEqual(rect, NSRect(x: 0, y: 0, width: 150, height: 111.1))
    }

    func testMalformedDevelopJsonFallsBackToTheRecord() {
        let portrait = asset(width: 6336, height: 9520, develop: "not json [[")
        let landscape = asset(width: 9520, height: 6336, develop: "null")
        XCTAssertTrue(AssetCardView.isPortrait(portrait), "a bad blob must not turn a portrait cell landscape")
        XCTAssertFalse(AssetCardView.isPortrait(landscape))
        XCTAssertEqual(card(portrait).lastSwatchRect, NSRect(x: 34, y: 0, width: 83, height: 111.1))
    }

    // MARK: - A⑦ decode cost

    func testDecodeCostPerCell() throws {
        let develop = try portraitCropJSON()
        let assets = (0..<40).map { asset(id: "asset-\($0)", width: 9520, height: 6336, develop: develop) }
        // Cold: 40 distinct rows, each decoding its document once. Warm: the same screen again,
        // which is what a re-layout / scroll-back pays once the id-keyed answer cache is filled.
        let coldStart = Date()
        for a in assets { _ = AssetCardView.isPortrait(a) }
        let cold = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        for a in assets { _ = AssetCardView.isPortrait(a) }
        let warm = Date().timeIntervalSince(warmStart)
        print(String(format: "436 A⑦ isPortrait cold: %.4f ms/cell, 40 cells %.3f ms · "
                     + "warm: %.5f ms/cell, 40 cells %.4f ms",
                     cold * 1000 / 40, cold * 1000, warm * 1000 / 40, warm * 1000))
        XCTAssertEqual(assets.filter { AssetCardView.isPortrait($0) }.count, 40)
    }
}
