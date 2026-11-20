import XCTest
import PhotonsCore
@testable import PhotonsUI

/// **450 — 用过「宽高比校正」之后重新进入裁切，裁切框位置不对。**
///
/// The stored document is the authority for the rect; the crop tool seeds a draft from it on every
/// entry (`begin`) and on a photo switch (`reseedForPhotoChange`). Both seeds used to call
/// `canvasRect(fromSource:)` unconditionally, but 330's migration has **already** converted a
/// `.canvas` document, so that was a second `P → R → /extent` walk — a double map that is the
/// identity only for a pure scale. The fix is one expression, `editingCropOnCanvas(source:)`, shared
/// by both seeds and by `migrateCropToCanvasSpace`:
///
/// | case | what it proves |
/// |---|---|
/// | ① | a `.canvas` document re-enters on exactly its stored rect (the main criterion) |
/// | ② | the old arithmetic moves that rect by > 1e-3, so ① really catches the double map |
/// | ③ | a `.source` document seeds the same rect the migration writes (one expression) |
/// | ④ | a photo switch in the tool re-seeds the converted rect, never the bare stored one |
///
/// The document carries the reported ingredients — `perspective(v:30, h:10, k:0.05)`,
/// `perspectiveAspect = 1.3`, and a non-full crop — so none of the four can pass on an identity.
@MainActor
final class CropReentryAfterAspect450Tests: XCTestCase {

    private var workDir: URL!
    private var defaults: UserDefaults!
    private var defaultSuites: [String] = []

    /// `0.2 / 0.15 / 0.8 / 0.85` — the rect the dispatch names, off every edge.
    private let storedCrop = CropRect(left: 0.2, top: 0.15, right: 0.8, bottom: 0.85)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-450-crop-reentry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // 317's preference is read at entry and can inscribe the draft; a fresh suite keeps this
        // file about the seed and nothing else.
        let name = "photons.crop450.\(UUID().uuidString)"
        defaultSuites.append(name)
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
    }

    override func tearDownWithError() throws {
        for name in defaultSuites { defaults?.removePersistentDomain(forName: name) }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    /// Writes the reported document. `space` is the only thing ①/③/④ vary: `.canvas` is a document
    /// the ingest migration has already converted, `.source` is one a tool session sees first.
    private func writeDocument(_ session: CatalogSession, space: CropSpace) {
        session.applyEdit { edit in
            edit.geometry.crop = self.storedCrop.normalizedRect
            edit.geometry.cropSpace = space
            edit.geometry.perspectiveVertical = 30
            edit.geometry.perspectiveHorizontal = 10
            edit.geometry.perspectiveShear = 0.05
            edit.geometry.perspectiveAspect = 1.3
        }
        session.commitEdit(label: "450 夹具", coalesce: false)
    }

    private func makeSession() throws -> CatalogSession {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        return session
    }

    /// Every edge compared separately, so a failure names the side that moved (normalized units).
    private func assertRect(_ actual: CropRect, _ expected: CropRect, accuracy: Double,
                            _ message: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let note = message()
        XCTAssertEqual(actual.left, expected.left, accuracy: accuracy,
                       "\(note) · left", file: file, line: line)
        XCTAssertEqual(actual.top, expected.top, accuracy: accuracy,
                       "\(note) · top", file: file, line: line)
        XCTAssertEqual(actual.right, expected.right, accuracy: accuracy,
                       "\(note) · right", file: file, line: line)
        XCTAssertEqual(actual.bottom, expected.bottom, accuracy: accuracy,
                       "\(note) · bottom", file: file, line: line)
    }

    /// The largest edge difference, in normalized units — the "how far did it move" number.
    private func worstEdgeDelta(_ a: CropRect, _ b: CropRect) -> Double {
        max(max(abs(a.left - b.left), abs(a.top - b.top)),
            max(abs(a.right - b.right), abs(a.bottom - b.bottom)))
    }

    // MARK: - ① the main criterion: a migrated document re-enters on its stored rect

    func testOneCanvasSpacedDocumentReopensOnItsStoredRect() throws {
        let session = try makeSession()
        writeDocument(session, space: .canvas)
        let tool = CropToolController(session: session, defaults: defaults)
        let stored = session.edit.geometry.cropRect
        let storedSpace = session.edit.geometry.cropSpace

        XCTAssertTrue(tool.begin(), "450 ①: 进不了裁切模式")
        print(String(format: "450 ① · 文档 %@ crop (%.6f,%.6f,%.6f,%.6f) · 草稿 %@ crop"
                     + " (%.6f,%.6f,%.6f,%.6f) · 边差 %.3e",
                     storedSpace == .canvas ? ".canvas" : ".source",
                     stored.left, stored.top, stored.right, stored.bottom,
                     tool.draft.cropSpace == .canvas ? ".canvas" : ".source",
                     tool.draft.crop.left, tool.draft.crop.top,
                     tool.draft.crop.right, tool.draft.crop.bottom,
                     worstEdgeDelta(tool.draft.crop, stored)))

        XCTAssertEqual(tool.draft.cropSpace, .canvas, "450 ①: 草稿必须在画布空间")
        assertRect(tool.draft.crop, stored, accuracy: 1e-9,
                   "450 ①: 已迁移文档重新进裁切，草稿必须逐边等于文档存储的矩形")
    }

    // MARK: - ② the reverse gate: the old arithmetic really is a double map

    func testTwoTheOldArithmeticMovesTheFrame() throws {
        let session = try makeSession()
        writeDocument(session, space: .canvas)
        let tool = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(tool.begin(), "450 ②: 进不了裁切模式")

        // The pre-450 seed, spelled exactly as `begin()` used to: a `.canvas` rect is fed to
        // `canvasRect(fromSource:)` as if it were source-normalized.
        let effective = CropGeometry(geometry: session.edit.geometry, source: tool.sourceSize)
        let oldArithmetic = effective.canvasRect(fromSource: effective.crop)
        let fixed = tool.draft.crop
        let delta = worstEdgeDelta(oldArithmetic, fixed)
        print(String(format: "450 ② · 旧算术 crop (%.6f,%.6f,%.6f,%.6f) · 新种子"
                     + " (%.6f,%.6f,%.6f,%.6f) · 最大边差 %.3e（归一化）",
                     oldArithmetic.left, oldArithmetic.top,
                     oldArithmetic.right, oldArithmetic.bottom,
                     fixed.left, fixed.top, fixed.right, fixed.bottom, delta))

        XCTAssertGreaterThan(delta, 1e-3,
            "450 ②: 旧算术与修复后的草稿几乎一样 —— 这条用例抓不到 double map，没有判别力")
    }

    // MARK: - ③ a source-spaced document seeds the migration's own result

    func testThreeSourceSpacedDocumentSeedsTheMigrationResult() throws {
        let session = try makeSession()
        writeDocument(session, space: .source)
        let tool = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(tool.begin(), "450 ③: 进不了裁切模式")

        var migrated = session.edit
        XCTAssertTrue(migrated.migrateCropToCanvasSpace(sourceSize: tool.sourceSize),
                      "450 ③: 夹具必须真的能被迁移")
        let expected = migrated.geometry.cropRect
        print(String(format: "450 ③ · 迁移结果 (%.6f,%.6f,%.6f,%.6f) · 草稿"
                     + " (%.6f,%.6f,%.6f,%.6f) · 边差 %.3e",
                     expected.left, expected.top, expected.right, expected.bottom,
                     tool.draft.crop.left, tool.draft.crop.top,
                     tool.draft.crop.right, tool.draft.crop.bottom,
                     worstEdgeDelta(tool.draft.crop, expected)))

        XCTAssertEqual(tool.draft.cropSpace, .canvas, "450 ③: 草稿必须在画布空间")
        assertRect(tool.draft.crop, expected, accuracy: 1e-9,
                   "450 ③: begin 与 migrateCropToCanvasSpace 必须是同一个表达式")
    }

    // MARK: - ④ a photo switch in the tool re-seeds the converted rect

    func testFourPhotoSwitchReSeedsTheConvertedRect() throws {
        let session = try makeSession()
        writeDocument(session, space: .source)
        let tool = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(tool.begin(), "450 ④: 进不了裁切模式")
        XCTAssertTrue(tool.reseedForPhotoChange(), "450 ④: 换图种子失败")

        let bare = session.edit.geometry.cropRect
        let expected = CropGeometry(geometry: session.edit.geometry, source: tool.sourceSize)
            .editingCropOnCanvas(source: tool.sourceSize)
        print(String(format: "450 ④ · 裸 crop (%.6f,%.6f,%.6f,%.6f) · 换图草稿 %@"
                     + " (%.6f,%.6f,%.6f,%.6f) · 与裸值的边差 %.3e",
                     bare.left, bare.top, bare.right, bare.bottom,
                     tool.draft.cropSpace == .canvas ? ".canvas" : ".source",
                     tool.draft.crop.left, tool.draft.crop.top,
                     tool.draft.crop.right, tool.draft.crop.bottom,
                     worstEdgeDelta(tool.draft.crop, bare)))

        XCTAssertEqual(tool.draft.cropSpace, .canvas,
                       "450 ④: 换图后草稿必须在画布空间（与 begin 同口径）")
        XCTAssertGreaterThan(worstEdgeDelta(tool.draft.crop, bare), 1e-3,
            "450 ④: 换图草稿等于裸 crop —— 少做了一次转换")
        assertRect(tool.draft.crop, expected, accuracy: 1e-9,
                   "450 ④: 换图必须用同一个转换表达式")
    }
}
