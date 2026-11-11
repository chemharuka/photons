import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// §382 — 堆叠必须「看得见」。
///
/// The user's four sentences (2026-11-11 16:2x–16:3x) are the acceptance:
///
///   ① 三个面都要标出张数 —— grid, filmstrip and photo list (the list used to be a 14 pt view
///      below `AssetBadges`'s own `height > 16` guard, so it could never paint);
///   ② 列表写「堆叠x张」，第二行日期右侧右对齐;
///   ③ 文件名显示成「堆叠 XXX.dng」（只在显示层，`asset.filename` 不动）;
///   ④ 堆叠后星级/色标必须改得了也刷得出来 —— 这是同一个断链：`apply(snapshot)` 不会为 id 未变的
///      cell 重跑 provider，所以在屏的格子永远停在它出生时的那份元数据。
///
/// The fixture is the ticket's: **one stack of five + six independent photos**, and the stack is
/// built through the shipped path (`session.stackSelection()`, i.e. ⌘G) *after* the three surfaces
/// are on screen — that is what makes the "no scroll, no rebuild" half of ⑤ meaningful.
@MainActor
final class StackVisibility382Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-stack382-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    /// Eleven photos with distinct capture minutes; display order is `capture_time DESC`, so
    /// `photos[10]` (the 10th minute) sorts first. The five **newest** are the stack.
    private func makeSession() throws -> (CatalogSession, [Asset]) {
        let url = workDir.appendingPathComponent("S382.\(LibraryLayout.packageExtension)", isDirectory: true)
        let setup = try Catalog.create(at: url)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try setup.ensureRoot(for: src, mode: .reference)

        var photos: [Asset] = []
        for i in 0 ..< 11 {
            let name = String(format: "IMG_%04d.dng", i)
            try Data([0x00]).write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                              kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 6000, height: 4000,
                              captureTime: String(format: "2026-01-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-01-01 10:00",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try setup.dbQueue.write { db in try asset.insert(db) }
            photos.append(asset)
        }

        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(url)
        session.setSortOrder(.newestFirst)
        return (session, photos)
    }

    private struct Surfaces {
        let grid: AssetGridController
        let strip: FilmstripController
        let pane: BrowserPaneController
    }

    private func makeSurfaces(session: CatalogSession) -> Surfaces {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        window.contentView = content
        windows.append(window)

        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        content.addSubview(grid.view)

        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.view.frame = NSRect(x: 0, y: 800, width: 1600, height: WorkspaceLayout.filmstripHeight)
        content.addSubview(strip.view)

        let pane = BrowserPaneController(session: session)
        _ = pane.view
        _ = pane.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: 744))
        content.addSubview(pane.view)

        content.layoutSubtreeIfNeeded()
        pump(0.2)
        grid.view.layoutSubtreeIfNeeded()
        strip.view.layoutSubtreeIfNeeded()
        pump(0.2)
        return Surfaces(grid: grid, strip: strip, pane: pane)
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Paint a view and its visible subviews offscreen — the routine every badge test uses, because
    /// the badges live on an overlay above the thumbnail layer.
    @discardableResult
    private static func paint(_ view: NSView) -> NSRect {
        view.layout()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        for subview in view.subviews where !subview.isHidden { subview.draw(subview.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        return view.bounds
    }

    private func gridItem(_ grid: AssetGridController, id: String) -> AssetGridItem? {
        grid.visibleItem(forAssetID: id)
    }

    private func stripCell(_ strip: FilmstripController, id: String) -> FilmstripCell? {
        for path in strip.collectionView.indexPathsForVisibleItems() {
            guard let cell = strip.collectionView.item(at: path) as? FilmstripCell,
                  cell.cardView.asset?.id == id else { continue }
            return cell
        }
        return nil
    }

    private func rowCell(_ pane: BrowserPaneController, id: String) -> PhotoRowCell? {
        let table = pane.photoListForTesting
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PhotoRowCell,
                  cell.assetID == id else { continue }
            return cell
        }
        return nil
    }

    /// The swatch rect a grid card draws into (`bounds.height − 22`), the filmstrip's thumb
    /// (`height − 12`) and the row's 34 pt square. One place, so the three sets of numbers the
    /// acceptance prints are measured against the same thing the view measured against.
    private static func swatchRect(of card: AssetCardView) -> NSRect {
        NSRect(x: 0, y: 0, width: card.bounds.width,
               height: max(1, card.bounds.height - GridLayout.labelHeight))
    }

    private static func thumbRect(of card: FilmstripCard) -> NSRect {
        NSRect(x: 0, y: 0, width: card.bounds.width,
               height: max(1, card.bounds.height - WorkspaceLayout.filmstripCaptionHeight))
    }

    /// Build the stack through ⌘G while all three surfaces are on screen.
    private func stackTheNewestFive(session: CatalogSession) throws -> StackSummary {
        let newest = Array(session.assets.prefix(5))
        session.setSelection(Set(newest.map(\.id)), anchor: newest[0].id)
        let summary = try XCTUnwrap(session.stackSelection(), "⌘G 应当把 5 张变成一堆")
        XCTAssertEqual(summary.count, 5)
        return summary
    }

    // MARK: - ① 三个面都画出张数

    func testAllThreeSurfacesDrawTheStackCount() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.4)
        surfaces.grid.view.layoutSubtreeIfNeeded()
        surfaces.strip.view.layoutSubtreeIfNeeded()
        pump(0.2)

        let top = try XCTUnwrap(session.assets.first { $0.id == summary.topID })

        let gridCell = try XCTUnwrap(gridItem(surfaces.grid, id: top.id), "网格里应在屏")
        Self.paint(gridCell.cardView)
        XCTAssertTrue(gridCell.cardView.lastDrawnBadges.contains("stack:5"),
                      "① 网格卡片有 stack:5，实际 \(gridCell.cardView.lastDrawnBadges)")

        let filmCell = try XCTUnwrap(stripCell(surfaces.strip, id: top.id), "胶片条里应在屏")
        Self.paint(filmCell.cardView)
        XCTAssertTrue(filmCell.cardView.lastDrawnBadges.contains("stack:5"),
                      "① 胶片条有 stack:5，实际 \(filmCell.cardView.lastDrawnBadges)")

        let row = try XCTUnwrap(rowCell(surfaces.pane, id: top.id), "列表里应有这一行")
        Self.paint(row)
        XCTAssertTrue(row.lastDrawnBadges.contains("stack:5"),
                      "① 列表行有 stack:5，实际 \(row.lastDrawnBadges)")
        print("① grid \(gridCell.cardView.lastDrawnBadges) "
              + "strip \(filmCell.cardView.lastDrawnBadges) row \(row.lastDrawnBadges)")
    }

    // MARK: - ② 列表第二行右对齐的「堆叠5张」

    func testTheRowSecondLineEndsWithTheStackCountAndNonStacksHideIt() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.4)

        let top = try XCTUnwrap(session.assets.first { $0.id == summary.topID })
        let stackedRow = try XCTUnwrap(rowCell(surfaces.pane, id: top.id))
        stackedRow.layout()
        XCTAssertEqual(stackedRow.stackLabelText, "堆叠5张", "② 逐字符：堆叠5张")
        XCTAssertFalse(stackedRow.stackLabelIsHidden, "② 堆叠行不隐藏")
        // Right-aligned inside the meta column, on the same baseline.
        XCTAssertEqual(stackedRow.stackLabelFrame.maxY, stackedRow.metaFrame.maxY, accuracy: 0.01,
                       "② 与 meta 同一条基线")
        XCTAssertEqual(stackedRow.stackLabelFrame.height, stackedRow.metaFrame.height, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(stackedRow.stackLabelFrame.minX,
                                    stackedRow.metaFrame.maxX + 4 - 0.01,
                                    "② meta 与「堆叠5张」之间 ≥ 4 pt")

        let plain = try XCTUnwrap(session.assets.first { $0.id != top.id && $0.stackId == nil })
        let plainRow = try XCTUnwrap(rowCell(surfaces.pane, id: plain.id))
        plainRow.layout()
        XCTAssertEqual(plainRow.stackLabelText, "")
        XCTAssertTrue(plainRow.stackLabelIsHidden, "② 非堆叠行隐藏（且不留空白占位）")
        XCTAssertFalse(plainRow.lastDrawnBadges.contains { $0.hasPrefix("stack:") })
        print("② stacked \"\(stackedRow.stackLabelText)\" frame \(stackedRow.stackLabelFrame) "
              + "meta \(stackedRow.metaFrame) | plain \"\(plainRow.stackLabelText)\" "
              + "hidden=\(plainRow.stackLabelIsHidden)")
    }

    // MARK: - ③ 文件名「堆叠 XXX.dng」，按拼好的整串截断

    func testTheFilenameCarriesTheStackPrefixOnAllThreeSurfaces() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.4)
        surfaces.grid.view.layoutSubtreeIfNeeded()
        surfaces.strip.view.layoutSubtreeIfNeeded()
        pump(0.2)

        let top = try XCTUnwrap(session.assets.first { $0.id == summary.topID })
        let full = "堆叠 " + top.filename

        let gridCell = try XCTUnwrap(gridItem(surfaces.grid, id: top.id))
        Self.paint(gridCell.cardView)
        let gridCaption = try XCTUnwrap(gridCell.cardView.lastDrawnCaption)
        let gridWidth = gridCell.cardView.lastCaptionRect.width
        XCTAssertTrue(gridCaption.hasPrefix("堆叠 "), "③ 网格 caption 有前缀：\(gridCaption)")
        XCTAssertEqual(gridCaption,
                       PlaceholderStyle.fitted(full, width: gridWidth,
                                               font: PlaceholderStyle.captionFont),
                       "③ 网格按拼好的整串截断（不是先截原名再贴前缀）")
        XCTAssertEqual(gridCell.cardView.asset?.filename, top.filename, "③ 模型里的文件名没变")

        let filmCell = try XCTUnwrap(stripCell(surfaces.strip, id: top.id))
        Self.paint(filmCell.cardView)
        let filmCaption = try XCTUnwrap(filmCell.cardView.lastDrawnCaption)
        let filmWidth = filmCell.cardView.lastCaptionRect.width
        XCTAssertTrue(filmCaption.hasPrefix("堆叠 "), "③ 胶片条 caption 有前缀：\(filmCaption)")
        XCTAssertEqual(filmCaption,
                       PlaceholderStyle.fitted(full, width: filmWidth,
                                               font: PlaceholderStyle.captionFont),
                       "③ 胶片条按拼好的整串截断")

        let row = try XCTUnwrap(rowCell(surfaces.pane, id: top.id))
        row.layout()
        let probe = row.layoutProbe
        XCTAssertTrue(probe.nameDrawnText.hasPrefix("堆叠 "),
                      "③ 列表 name 有前缀：\(probe.nameDrawnText)")
        XCTAssertEqual(probe.nameText, top.filename, "③ 行里保留的是原名，不是拼接串")
        XCTAssertEqual(probe.nameDrawnText,
                       PlaceholderStyle.fitted(full, width: probe.name.width,
                                               font: NSFont.systemFont(ofSize: 11, weight: .medium)),
                       "③ 列表按拼好的整串截断")
        print("③ grid \"\(gridCaption)\" @\(gridWidth) | film \"\(filmCaption)\" @\(filmWidth) "
              + "| row \"\(probe.nameDrawnText)\" @\(probe.name.width)")
    }

    // MARK: - ④ 四个角：张数左下、旗标+色标左上、右上空

    func testTheFourCornersAreTheOnesTheTicketNames() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.4)
        // A flag and a colour label so the top-left capsule has both halves to draw.
        session.selectOnly(summary.topID)
        XCTAssertTrue(session.setRatingForSelection(3))
        XCTAssertTrue(session.setFlagForSelection("pick"))
        XCTAssertTrue(session.setColorLabelForSelection("red"))
        pump(0.5)
        surfaces.grid.view.layoutSubtreeIfNeeded()
        surfaces.strip.view.layoutSubtreeIfNeeded()

        let top = try XCTUnwrap(session.assets.first { $0.id == summary.topID })

        // grid
        let gridCell = try XCTUnwrap(gridItem(surfaces.grid, id: top.id))
        Self.paint(gridCell.cardView)
        let gridRect = Self.swatchRect(of: gridCell.cardView)
        let g = gridCell.cardView.lastBadgeLayout
        let gp = try XCTUnwrap(g.stackPill, "④ 网格：张数胶囊")
        let gf = try XCTUnwrap(g.flagPill, "④ 网格：旗标胶囊")
        XCTAssertGreaterThanOrEqual(gp.minX - gridRect.minX, 0)
        XCTAssertLessThanOrEqual(gp.minX - gridRect.minX, 6, "④ 网格：张数距左边 ≤ 6")
        XCTAssertGreaterThanOrEqual(gridRect.maxY - gp.maxY, 0)
        XCTAssertLessThanOrEqual(gridRect.maxY - gp.maxY, 6, "④ 网格：张数距底边 ≤ 6")
        XCTAssertLessThanOrEqual(gf.maxX, gridRect.midX, "④ 网格：旗标胶囊不越中线（右上无徽标）")
        XCTAssertLessThanOrEqual(gf.minY - gridRect.minY, 6, "④ 网格：旗标贴顶边")
        // 旗标与色标并排：同一行（ΔcenterY ≤ 1），旗标在左。
        let gGlyph = try XCTUnwrap(g.flagGlyphRect, "④ 网格：旗标字形")
        let gDot = try XCTUnwrap(g.colorDotRect, "④ 网格：色点")
        XCTAssertLessThanOrEqual(abs(gDot.midY - gGlyph.midY), 1,
                                 "④ 网格：旗标与色点同一行（ΔcenterY \(abs(gDot.midY - gGlyph.midY))）")
        XCTAssertLessThanOrEqual(gGlyph.maxX, gDot.minX, "④ 网格：旗标在色点左侧")
        // The stars sit on the same baseline, to the right of the count.
        let gs = try XCTUnwrap(g.starsPill, "④ 网格：星级胶囊")
        XCTAssertEqual(gs.minY, gp.minY, accuracy: 1, "④ 网格：星级与张数同基线")
        XCTAssertGreaterThanOrEqual(gs.minX, gp.maxX + 2.99, "④ 网格：星级在张数右侧 3 pt")
        XCTAssertLessThanOrEqual(gs.maxX, gridRect.maxX, "④ 网格：徽标总和不出缩略图")
        XCTAssertLessThanOrEqual(gf.maxX, gridRect.maxX)
        // 右上角空：no capsule from this layout occupies the top-right quadrant's corner.
        for (name, rect) in [("stack", gp), ("stars", gs), ("flag", gf)] {
            // "In the top-right corner" = anchored to the right half AND on the top row.
            let inTopRight = rect.minX > gridRect.midX && rect.minY < gridRect.minY + 16
            XCTAssertFalse(inTopRight, "④ 网格：右上角应有徽标 \(name) \(rect)")
        }
        print("④ grid stack \(gp) flag \(gf) glyph \(gGlyph) dot \(gDot) stars \(gs) "
              + "swatch \(gridRect)")

        // filmstrip
        let filmCell = try XCTUnwrap(stripCell(surfaces.strip, id: top.id))
        Self.paint(filmCell.cardView)
        let filmRect = Self.thumbRect(of: filmCell.cardView)
        let f = filmCell.cardView.lastBadgeLayout
        let fp = try XCTUnwrap(f.stackPill, "④ 胶片条：张数胶囊")
        let ff = try XCTUnwrap(f.flagPill, "④ 胶片条：旗标胶囊")
        XCTAssertGreaterThanOrEqual(fp.minX - filmRect.minX, 0)
        XCTAssertLessThanOrEqual(fp.minX - filmRect.minX, 6)
        XCTAssertGreaterThanOrEqual(filmRect.maxY - fp.maxY, 0)
        XCTAssertLessThanOrEqual(filmRect.maxY - fp.maxY, 6)
        XCTAssertLessThanOrEqual(ff.maxX, filmRect.midX)
        XCTAssertLessThanOrEqual(ff.minY - filmRect.minY, 6)
        let fGlyph = try XCTUnwrap(f.flagGlyphRect, "④ 胶片条：旗标字形")
        let fDot = try XCTUnwrap(f.colorDotRect, "④ 胶片条：色点")
        XCTAssertLessThanOrEqual(abs(fDot.midY - fGlyph.midY), 1,
                                 "④ 胶片条：旗标与色点同一行")
        XCTAssertLessThanOrEqual(fGlyph.maxX, fDot.minX, "④ 胶片条：旗标在色点左侧")
        XCTAssertLessThanOrEqual(fp.maxX, filmRect.maxX)
        // The stars are the one badge that may be dropped (never the count) when a cell is too
        // narrow for both; either way nothing may leave the thumbnail.
        for pill in [f.starsPill].compactMap({ $0 }) {
            XCTAssertLessThanOrEqual(pill.maxX, filmRect.maxX - AssetBadges.BadgeMetrics.inset + 0.01,
                                     "④ 胶片条：星级胶囊不出缩略图")
        }
        // At the shipped 90 pt cell a 3-star pill does fit, and it sits on the count's baseline.
        if let fs = f.starsPill {
            XCTAssertEqual(fs.minY, fp.minY, accuracy: 1, "④ 胶片条：星级与张数同基线")
            XCTAssertGreaterThanOrEqual(fs.minX, fp.maxX + 2.99, "④ 胶片条：星级在张数右侧 3 pt")
        }
        for (name, rect) in [("stack", fp), ("flag", ff)] {
            let inTopRight = rect.minX > filmRect.midX && rect.minY < filmRect.minY + 16
            XCTAssertFalse(inTopRight, "④ 胶片条：右上角应有徽标 \(name) \(rect)")
        }
        print("④ film stack \(fp) flag \(ff) glyph \(fGlyph) dot \(fDot) stars \(f.starsPill.map(String.init(describing:)) ?? "—") thumb \(filmRect)")

        // photo list row (the 34 pt square; stars are the row's own text line)
        let row = try XCTUnwrap(rowCell(surfaces.pane, id: top.id))
        Self.paint(row)
        XCTAssertEqual(row.lastDrawnBadges.sorted(),
                       ["color:red", "flag:pick", "stack:5", "stars:3"],
                       "④ 列表角标带齐四项，实际 \(row.lastDrawnBadges)")
        let square = row.stackBadgeFrame
        XCTAssertEqual(square.width, 34, accuracy: 0.01, "④ 列表：角标 frame 是整张 34 pt 方块")
        XCTAssertEqual(square.height, 34, accuracy: 0.01, "④ 列表：角标 frame 是整张 34 pt 方块")
        // The layout rects are in the **badge view's** own coordinates (it is pinned to the square),
        // so the square for these comparisons is the view's bounds, not its frame in the row.
        let badgeRect = NSRect(origin: .zero, size: square.size)
        let rp = try XCTUnwrap(row.stackBadgeLayout.stackPill, "④ 列表：张数胶囊")
        XCTAssertGreaterThanOrEqual(rp.minX - badgeRect.minX, 0)
        XCTAssertLessThanOrEqual(rp.minX - badgeRect.minX, 6, "④ 列表：张数距方块左边 ≤ 6")
        XCTAssertGreaterThanOrEqual(badgeRect.maxY - rp.maxY, 0)
        XCTAssertLessThanOrEqual(badgeRect.maxY - rp.maxY, 6, "④ 列表：张数距方块底边 ≤ 6")
        let rGlyph = try XCTUnwrap(row.stackBadgeLayout.flagGlyphRect, "④ 列表：旗标字形")
        let rDot = try XCTUnwrap(row.stackBadgeLayout.colorDotRect, "④ 列表：色点")
        XCTAssertLessThanOrEqual(abs(rDot.midY - rGlyph.midY), 1, "④ 列表：旗标与色点同一行")
        XCTAssertLessThanOrEqual(rGlyph.maxX, rDot.minX, "④ 列表：旗标在色点左侧")
        for (name, rect) in [("stack", rp), ("flag", try XCTUnwrap(row.stackBadgeLayout.flagPill))] {
            let inTopRight = rect.minX > badgeRect.midX && rect.minY < 16
            XCTAssertFalse(inTopRight, "④ 列表：右上角应有徽标 \(name) \(rect)")
        }
        print("④ row square \(square) badgeRect \(badgeRect) stack \(rp) glyph \(rGlyph) dot \(rDot) "
              + "badges \(row.lastDrawnBadges)")
    }

    // MARK: - ⑤ 断链已修：写入后**在屏**的 cell 不滚动、不重建就变

    func testAnOnScreenCellPicksUpTheStackWithoutScrolling() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)

        let firstID = session.assets[0].id
        let gridCell = try XCTUnwrap(gridItem(surfaces.grid, id: firstID))
        let filmCell = try XCTUnwrap(stripCell(surfaces.strip, id: firstID))
        XCTAssertEqual(gridCell.cardView.stackCount, 0, "⑤ 前置：还没堆叠")
        XCTAssertEqual(filmCell.cardView.stackCount, 0, "⑤ 前置：还没堆叠")
        let gridCardBefore = gridCell.cardView
        let filmCardBefore = filmCell.cardView

        _ = try stackTheNewestFive(session: session)
        pump(0.6)
        surfaces.grid.view.layoutSubtreeIfNeeded()
        surfaces.strip.view.layoutSubtreeIfNeeded()
        pump(0.2)

        // Same cell object, same asset id: no recycle, no scroll.
        let gridAfter = try XCTUnwrap(gridItem(surfaces.grid, id: firstID), "⑤ 置顶仍在屏上")
        XCTAssertTrue(gridAfter.cardView === gridCardBefore, "⑤ 网格 cell 没被重建")
        XCTAssertEqual(gridAfter.cardView.asset?.id, firstID)
        XCTAssertEqual(gridAfter.cardView.stackCount, 5, "⑤ 在屏网格 cell 的 stackCount 变成 5")
        Self.paint(gridAfter.cardView)
        XCTAssertTrue(gridAfter.cardView.lastDrawnBadges.contains("stack:5"))

        let filmAfter = try XCTUnwrap(stripCell(surfaces.strip, id: firstID), "⑤ 置顶仍在胶片条上")
        XCTAssertTrue(filmAfter.cardView === filmCardBefore, "⑤ 胶片条 cell 没被重建")
        XCTAssertEqual(filmAfter.cardView.stackCount, 5, "⑤ 在屏胶片条 cell 的 stackCount 变成 5")
        Self.paint(filmAfter.cardView)
        XCTAssertTrue(filmAfter.cardView.lastDrawnBadges.contains("stack:5"))
        print("⑤ grid stackCount \(gridAfter.cardView.stackCount) "
              + "strip \(filmAfter.cardView.stackCount) sameCell="
              + "\(gridAfter.cardView === gridCardBefore)/\(filmAfter.cardView === filmCardBefore)")
    }

    // MARK: - ⑤b 列表确实重配了每一行（不需要改代码，但要有证据）

    /// §2.1 — the list is the one surface that did **not** need the new repaint path: its `refresh()`
    /// calls `photosTable.reloadData()`, which re-asks `tableView(_:viewFor:row:)` for every visible
    /// row. This is that claim as an observation: the row that was on screen before the stack is
    /// still showing the same photo afterwards, and it now paints 「堆叠5张」 — with no scroll.
    func testThePhotoListReconfiguresItsRowsOnARefresh() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let firstID = session.assets[0].id
        let before = try XCTUnwrap(rowCell(surfaces.pane, id: firstID))
        before.layout()
        XCTAssertEqual(before.stackLabelText, "", "⑤b 前置：还没堆叠")

        _ = try stackTheNewestFive(session: session)
        pump(0.6)
        surfaces.pane.view.layoutSubtreeIfNeeded()
        pump(0.2)

        let after = try XCTUnwrap(rowCell(surfaces.pane, id: firstID), "⑤b 置顶仍在列表里")
        after.layout()
        XCTAssertEqual(after.assetID, firstID, "⑤b 这一行还是那张照片")
        XCTAssertEqual(after.stackCount, 5, "⑤b 行的 stackCount 变成 5（reloadData 重配过）")
        XCTAssertEqual(after.stackLabelText, "堆叠5张", "⑤b 且第二行右标签已经画上")
        Self.paint(after)
        XCTAssertTrue(after.lastDrawnBadges.contains("stack:5"))
        print("⑤b list row stackCount \(after.stackCount) label \"\(after.stackLabelText)\" "
              + "badges \(after.lastDrawnBadges)")
    }

    // MARK: - ⑥ 星级 / 色标：写得进，也同一帧刷得出

    func testRatingAndColourLabelRepaintAllThreeSurfacesInTheSameFrame() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.5)

        session.selectOnly(summary.topID)
        XCTAssertTrue(session.setRatingForSelection(3))
        XCTAssertTrue(session.setColorLabelForSelection("red"))
        pump(0.6)
        surfaces.grid.view.layoutSubtreeIfNeeded()
        surfaces.strip.view.layoutSubtreeIfNeeded()

        let top = try XCTUnwrap(session.assets.first { $0.id == summary.topID })

        let gridCell = try XCTUnwrap(gridItem(surfaces.grid, id: top.id))
        Self.paint(gridCell.cardView)
        let gridDrawn = gridCell.cardView.lastDrawnBadges
        XCTAssertTrue(gridDrawn.contains("stars:3"), "⑥ 网格：stars:3（实际 \(gridDrawn)）")
        XCTAssertTrue(gridDrawn.contains("color:red"), "⑥ 网格：color:red（实际 \(gridDrawn)）")

        let filmCell = try XCTUnwrap(stripCell(surfaces.strip, id: top.id))
        Self.paint(filmCell.cardView)
        let filmDrawn = filmCell.cardView.lastDrawnBadges
        XCTAssertTrue(filmDrawn.contains("stars:3"), "⑥ 胶片条：stars:3（实际 \(filmDrawn)）")
        XCTAssertTrue(filmDrawn.contains("color:red"), "⑥ 胶片条：color:red（实际 \(filmDrawn)）")

        let row = try XCTUnwrap(rowCell(surfaces.pane, id: top.id))
        Self.paint(row)
        let rowDrawn = row.lastDrawnBadges
        XCTAssertTrue(rowDrawn.contains("stars:3"), "⑥ 列表：stars:3（实际 \(rowDrawn)）")
        XCTAssertTrue(rowDrawn.contains("color:red"), "⑥ 列表：color:red（实际 \(rowDrawn)）")
        print("⑥ grid \(gridDrawn) strip \(filmDrawn) row \(rowDrawn)")
    }

    // MARK: - ⑨ 非堆叠无污染

    func testTheSixIndependentPhotosCarryNoStackMarkers() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.4)
        surfaces.grid.view.layoutSubtreeIfNeeded()
        surfaces.strip.view.layoutSubtreeIfNeeded()
        pump(0.2)

        let plain = session.assets.filter { $0.stackId == nil && $0.id != summary.topID }
        XCTAssertEqual(plain.count, 6, "⑨ 6 张独立照片")

        for asset in plain {
            let gridCell = try XCTUnwrap(gridItem(surfaces.grid, id: asset.id), "网格 \(asset.filename)")
            Self.paint(gridCell.cardView)
            XCTAssertFalse(gridCell.cardView.lastDrawnBadges.contains { $0.hasPrefix("stack:") },
                           "⑨ 网格 \(asset.filename) 无 stack:")
            XCTAssertFalse(gridCell.cardView.lastDrawnCaption?.hasPrefix("堆叠 ") ?? false,
                           "⑨ 网格 \(asset.filename) 无前缀")
            XCTAssertEqual(gridCell.cardView.lastDrawnCaption,
                           PlaceholderStyle.fitted(asset.filename,
                                                   width: gridCell.cardView.lastCaptionRect.width,
                                                   font: PlaceholderStyle.captionFont))

            let filmCell = try XCTUnwrap(stripCell(surfaces.strip, id: asset.id), "胶片条 \(asset.filename)")
            Self.paint(filmCell.cardView)
            XCTAssertFalse(filmCell.cardView.lastDrawnBadges.contains { $0.hasPrefix("stack:") },
                           "⑨ 胶片条 \(asset.filename) 无 stack:")
            XCTAssertFalse(filmCell.cardView.lastDrawnCaption?.hasPrefix("堆叠 ") ?? false,
                           "⑨ 胶片条 \(asset.filename) 无前缀")

            let row = try XCTUnwrap(rowCell(surfaces.pane, id: asset.id), "列表 \(asset.filename)")
            row.layout()
            Self.paint(row)
            XCTAssertFalse(row.lastDrawnBadges.contains { $0.hasPrefix("stack:") },
                           "⑨ 列表 \(asset.filename) 无 stack:")
            XCTAssertFalse(row.layoutProbe.nameDrawnText.hasPrefix("堆叠 "),
                           "⑨ 列表 \(asset.filename) 无前缀")
            XCTAssertTrue(row.stackLabelIsHidden, "⑨ 列表 \(asset.filename) 右标签隐藏")
            XCTAssertEqual(row.stackLabelText, "")
        }
        print("⑨ 6 张独立照片：三面都无 stack: / 无「堆叠 」/ 列表右标签隐藏")
    }

    // MARK: - ⑦ --ui-smoke 的色点像素探针仍然指得准

    /// The smoke's `badgeDotPresent` used to look in the swatch's top-**right** box. §382 moved the
    /// dot into the shared flag+colour capsule in the top-**left** corner, so the probe's box moved
    /// with it. This test is the probe, run against a real render: the label's own colour is found
    /// inside the capsule, and the same card with no label has none of it.
    func testTheSmokeDotProbeStillFindsTheDotInTheNewCorner() throws {
        let (session, _) = try makeSession()
        let surfaces = makeSurfaces(session: session)
        let summary = try stackTheNewestFive(session: session)
        pump(0.4)

        let top = try XCTUnwrap(session.assets.first { $0.id == summary.topID })
        session.selectOnly(summary.topID)
        XCTAssertTrue(session.setColorLabelForSelection("red"))
        pump(0.5)
        surfaces.grid.view.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(gridItem(surfaces.grid, id: top.id)?.cardView)
        XCTAssertTrue(dotPresent(in: card, label: .red), "⑦ 左上胶囊里能找到色点的红色")
        XCTAssertFalse(dotPresent(in: card, label: .blue), "⑦ 找不到没有画过的蓝色")
        print("⑦ dot red found=\(dotPresent(in: card, label: .red)) "
              + "blue found=\(dotPresent(in: card, label: .blue))")
    }

    /// The same HSB search the smoke uses, over the capsule's dot half.
    private func dotPresent(in card: AssetCardView, label: ColorLabel) -> Bool {
        let rect = card.bounds
        guard rect.width > 40, rect.height > 40,
              let rep = card.bitmapImageRepForCachingDisplay(in: rect) else { return false }
        card.cacheDisplay(in: rect, to: rep)
        let target = label.color.usingColorSpace(.sRGB) ?? label.color
        var tHue: CGFloat = 0, tSat: CGFloat = 0, tBri: CGFloat = 0, tAlpha: CGFloat = 0
        target.getHue(&tHue, saturation: &tSat, brightness: &tBri, alpha: &tAlpha)
        let sx = CGFloat(rep.pixelsWide) / max(1, rect.width)
        let sy = CGFloat(rep.pixelsHigh) / max(1, rect.height)
        let box = NSRect(x: rect.minX + 13, y: rect.minY + 2, width: 14, height: 16)
        for py in Int(box.minY * sy)..<Int(box.maxY * sy) {
            for px in Int(box.minX * sx)..<Int(box.maxX * sx) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
                c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
                let delta = min(abs(hue - tHue), 1 - abs(hue - tHue))
                if delta < 0.06, abs(sat - tSat) < 0.30, abs(bri - tBri) < 0.20 { return true }
            }
        }
        return false
    }

    // MARK: - ⑩ 一：既有徽章口径没变（新增字段不污染 drawn）

    func testTheDrawnVocabularyStaysTheOneTheSmokeReads() {
        let badges = AssetBadges(rating: 3, flag: "pick", colorLabel: "red", stackCount: 5)
        XCTAssertEqual(badges.drawn, ["stars:3", "flag:pick", "color:red", "stack:5"])
        XCTAssertEqual(badges.signature, "★3 ⚑ 红 ⧉5")
        // The new "how many" wording is a separate field, not a re-purposing of `drawn`.
        XCTAssertEqual(StackText.countLabel(5), "堆叠5张")
        XCTAssertEqual(StackText.displayName("A.dng", isStack: true), "堆叠 A.dng")
        XCTAssertEqual(StackText.displayName("A.dng", isStack: false), "A.dng")
    }
}
