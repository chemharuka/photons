import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 099 — the sheet's section order, the one-line summary, and the preset files behind the popup.
/// 106 — the HDR row's default/remembered state, the HDR export options, and the results layout.
@MainActor
final class ExportSheetModelTests: XCTestCase {

    private var scratch: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-sheet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.contentView = nil }
        windows = []
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// An isolated `UserDefaults`-shaped store: without it the sheet would read the developer's real
    /// export memory and the test would depend on what was exported on this machine.
    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        var writes = 0
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data; writes += 1 } else { values.removeValue(forKey: key) }
        }
    }

    private var draftStore: MemoryDraftStore!

    override func setUp() {
        super.setUp()
        draftStore = MemoryDraftStore()
    }

    private func model(writableUTIs: Set<String>? = nil) -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         writableUTIs: writableUTIs,
                         draftStore: draftStore)
    }

    // MARK: sections

    func testSectionOrderMatchesLightroom() {
        XCTAssertEqual(ExportSheetModel.sectionTitles,
                       ["位置", "文件命名", "文件设置", "图像尺寸", "元数据", "导出"])
    }

    // MARK: - 109 文件设置

    /// §4.1 — a format without an encoder is not in the row at all.
    func testTheFormatRowOnlyCarriesWritableFormats() {
        let partial = model(writableUTIs: [UTType.jpeg.identifier, UTType.heic.identifier,
                                           UTType.tiff.identifier])
        XCTAssertEqual(partial.availableFormats, [.jpeg, .heic, .tiff])
        XCTAssertEqual(partial.preset.format, .heic, "HEIC is the default draft")

        let all = model(writableUTIs: Set(ExportFormat.allCases.map { $0.utType.identifier }))
        XCTAssertEqual(all.availableFormats.count, 5)

        // A format the machine cannot write is ignored rather than silently selected.
        partial.selectFormat(.avif)
        XCTAssertEqual(partial.preset.format, .heic)
    }

    /// §4.4 + 161 §1/§9 — the default draft, field by field. It is the picture's own size now, at
    /// quality 0.85 (the user's 2026-10-30 口径), and no longer the 2048 「网络 2048」 draft.
    func testDefaultDraftIsHEICHDRP3At085AndOriginalSize() {
        let preset = ExportSheetModel.defaultPreset
        XCTAssertEqual(preset.format, .heic)
        XCTAssertEqual(preset.hdr?.enabled, true)
        XCTAssertEqual(preset.hdr?.gainMap, .iso)
        XCTAssertEqual(preset.quality, 0.85)
        XCTAssertEqual(preset.colorSpace, .displayP3)
        XCTAssertEqual(preset.bitDepth, 8)
        XCTAssertEqual(preset.sdrToneMapping, .global)
        XCTAssertEqual(preset.conflict, .rename)
        XCTAssertEqual(preset.sizingMode, .none)
        XCTAssertNil(preset.longEdge)
        XCTAssertEqual(preset.name, "默认")

        // 网络 2048 is still a selectable preset with its own quality/size.
        XCTAssertEqual(ExportSheetModel.network2048Preset.longEdge, 2048)
        XCTAssertEqual(ExportSheetModel.network2048Preset.quality, 0.95)
        XCTAssertTrue(ExportSheetModel.builtInPresetNames.contains("网络 2048"))
    }

    /// 161 §2 — the popup order is 原尺寸 / 长边 / 比例, while `allCases` keeps the stored order.
    func testSizingModesDisplayOriginalFirstWithoutChangingStorageOrder() {
        XCTAssertEqual(ExportSizingMode.displayOrder, [.none, .longEdge, .percent])
        XCTAssertEqual(ExportSizingMode.allCases, [.longEdge, .percent, .none])
    }

    /// §4.5 — the summary says P3 (the 099 summary assertion moved with the default).
    func testDefaultColourIsP3AndTheSummarySaysSo() {
        let sheet = model()
        XCTAssertEqual(sheet.preset.colorSpace, .displayP3)
        XCTAssertTrue(sheet.summaryLine.contains("Display P3"), sheet.summaryLine)
        XCTAssertFalse(sheet.summaryLine.contains("sRGB"), sheet.summaryLine)
        XCTAssertEqual(ExportPreset().colorSpace, .displayP3,
                       "默认色彩从 sRGB 改 P3 是用户 2026-10-29 的口径")
    }

    /// §4.2 — HDR on shows the gain-map row and hides tone mapping; off is the reverse.
    func testHDRAndSDRRowsAreMutuallyExclusive() {
        let sheet = model()
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertTrue(sheet.showsGainMapRows)
        XCTAssertFalse(sheet.showsToneMappingRow)
        XCTAssertEqual(sheet.sdrToneMapping, .global)

        sheet.setHDR(false)
        XCTAssertFalse(sheet.hdrEnabled)
        XCTAssertFalse(sheet.showsGainMapRows)
        XCTAssertTrue(sheet.showsToneMappingRow)
        sheet.setSDRToneMapping(.none)
        XCTAssertEqual(sheet.preset.sdrToneMapping, .none)
    }

    /// 168 §1 — PQ/HLG are single-picture HDR paths: neither a gain-map row nor an SDR tone-map row.
    /// Before this the view's `else` (keyed only on `showsGainMapRows`) painted 色调映射 under them.
    func testPQAndHLGHideTheToneMappingRow() {
        let sheet = model()
        sheet.setHDR(true)

        sheet.setHDRKind(.pq)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertFalse(sheet.showsGainMapRows)
        XCTAssertFalse(sheet.showsToneMappingRow)

        sheet.setHDRKind(.hlg)
        XCTAssertEqual(sheet.hdrKind, .hlg)
        XCTAssertFalse(sheet.showsGainMapRows)
        XCTAssertFalse(sheet.showsToneMappingRow)

        sheet.setHDR(false)
        XCTAssertFalse(sheet.showsGainMapRows)
        XCTAssertTrue(sheet.showsToneMappingRow, "HDR 关必须有色调映射行")
    }

    /// 168 §3 — a typed quality writes only a legal 0.10–1.00 value, with two decimals in the box.
    /// An empty/non-numeric/out-of-range string leaves the previous legal value untouched.
    func testTypedQualityCommitsLegalValuesAndRejectsTheRest() {
        let sheet = model()
        XCTAssertEqual(sheet.qualityText, "0.85", "161 的默认质量仍是 0.85")

        XCTAssertTrue(sheet.commitQuality("0.92"))
        XCTAssertEqual(sheet.preset.quality, 0.92, accuracy: 1e-12)
        XCTAssertEqual(sheet.qualityText, "0.92")

        for bad in ["1.5", "abc", "", "  ", "0.05", "nan"] {
            XCTAssertFalse(sheet.commitQuality(bad), bad)
            XCTAssertEqual(sheet.preset.quality, 0.92, accuracy: 1e-12,
                           "非法值 \(bad) 不许回写文档")
        }
        XCTAssertEqual(sheet.qualityText, "0.92")
    }

    /// §4.3 — RGB + Apple is not reachable; each legal pair lands on the right `GainMap`.
    func testGainMapModelAndVersionMapToTheThreeSpellings() {
        let sheet = model()

        sheet.setGainMapColorModel(.rgb)
        sheet.setGainMapVersion(.iso)
        XCTAssertEqual(sheet.preset.hdr?.gainMap, .iso)
        XCTAssertEqual(sheet.gainMapColorModel, .rgb)
        XCTAssertEqual(sheet.gainMapVersion, .iso)

        sheet.setGainMapColorModel(.mono)
        sheet.setGainMapVersion(.iso)
        XCTAssertEqual(sheet.preset.hdr?.gainMap, .mono)
        XCTAssertEqual(sheet.gainMapColorModel, .mono)

        sheet.setGainMapColorModel(.mono)
        sheet.setGainMapVersion(.apple)
        XCTAssertEqual(sheet.preset.hdr?.gainMap, .apple)
        XCTAssertEqual(sheet.gainMapColorModel, .mono)
        XCTAssertEqual(sheet.gainMapVersion, .apple)

        // Clicking RGB while Apple is selected locks the version back to ISO …
        sheet.setGainMapColorModel(.rgb)
        XCTAssertEqual(sheet.preset.hdr?.gainMap, .iso)
        XCTAssertEqual(sheet.gainMapVersion, .iso)
        // … and clicking Apple while RGB is selected locks the model to 黑白.
        sheet.setGainMapVersion(.apple)
        XCTAssertEqual(sheet.preset.hdr?.gainMap, .apple)
        XCTAssertEqual(sheet.gainMapColorModel, .mono)
        XCTAssertNoThrow(try sheet.preset.validated())
    }

    /// §1 / 108 — the depth row only offers legal values and clamps on a format switch. 216 — TIFF/PNG
    /// now start on PQ, whose depth is locked at 16; turning HDR off gives the container's menu back.
    func testBitDepthRowFollowsTheFormat() {
        let sheet = model()
        XCTAssertEqual(sheet.bitDepths, [8, 10])
        sheet.selectBitDepth(10)
        XCTAssertEqual(sheet.preset.bitDepth, 10)
        sheet.selectFormat(.jpeg)
        XCTAssertEqual(sheet.bitDepths, [8])
        XCTAssertEqual(sheet.preset.bitDepth, 8, "HEIC 10 → JPEG must not leave a hidden 10")
        sheet.selectFormat(.png)
        XCTAssertEqual(sheet.bitDepths, [16], "216: PNG's default PQ locks the depth at 16")
        XCTAssertEqual(sheet.preset.bitDepth, 16)
        sheet.setHDR(false)
        XCTAssertEqual(sheet.bitDepths, [8, 16], "an SDR PNG keeps the container's own menu")
        sheet.selectBitDepth(8)
        XCTAssertEqual(sheet.preset.bitDepth, 8)
        sheet.selectBitDepth(10)
        XCTAssertEqual(sheet.preset.bitDepth, 8, "10 is not a PNG depth")
    }

    // MARK: summary

    func testBottomSummaryIsExact() {
        let sheet = model()
        sheet.selectionCount = 3

        sheet.preset = ExportSheetModel.defaultPreset
        sheet.preset.format = .jpeg
        // 163 — JPEG can carry a gain map now; this test pins the SDR summary, so turn HDR off.
        sheet.preset.hdr = nil
        sheet.preset.longEdge = 2400
        sheet.preset.bitDepth = 8
        sheet.preset.colorSpace = .sRGB
        sheet.preset.sizingMode = .longEdge
        sheet.preset.conflict = .rename
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → JPEG · 8 位 · sRGB · 长边 2400 · 重命名 · 未放大")

        sheet.preset.format = .tiff
        sheet.preset.bitDepth = 16
        sheet.preset.colorSpace = .displayP3
        sheet.preset.sizingMode = .percent
        sheet.preset.percent = 60
        sheet.preset.conflict = .skip
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → TIFF · 16 位 · Display P3 · 长边 60% · 跳过 · 未放大")

        sheet.preset.format = .png
        sheet.preset.bitDepth = 8
        sheet.preset.colorSpace = .sRGB
        sheet.preset.longEdge = 1234
        sheet.preset.sizingMode = .none
        sheet.preset.conflict = .overwrite
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → PNG · 8 位 · sRGB · 原尺寸 · 覆盖")
    }

    // MARK: preset files

    func testSaveLoadAndDeleteAPreset() throws {
        let sheet = model()
        sheet.preset = ExportSheetModel.defaultPreset
        sheet.selectSizingMode(.longEdge)
        sheet.preset.longEdge = 2400
        sheet.preset.conflict = .skip

        XCTAssertTrue(sheet.savePreset(named: "网络 2048"))
        XCTAssertEqual(sheet.presetNames, ["网络 2048"])
        let file = scratch.appendingPathComponent("网络-2048.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        sheet.preset = ExportSheetModel.defaultPreset
        XCTAssertNil(sheet.preset.longEdge, "161: the factory draft is 原尺寸, not 2048")
        sheet.loadPreset(named: "网络 2048")
        XCTAssertEqual(sheet.preset.longEdge, 2400)
        XCTAssertEqual(sheet.preset.conflict, .skip)
        XCTAssertEqual(sheet.preset.name, "网络 2048")

        sheet.deletePreset(named: "网络 2048")
        XCTAssertTrue(sheet.presetNames.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSafePresetFilenameStripsPathCharacters() {
        XCTAssertEqual(ExportPresetStore.safeFilename("a/b:c d"), "a-b-c-d")
        XCTAssertEqual(ExportPresetStore.safeFilename("   "), "preset")
    }

    // MARK: - 106 HDR

    /// §A + §2: a fresh draft is HEIC with HDR on and ISO RGB gain maps, and the batch's own options
    /// carry the flag — that is the door `Exporter.write` checks before it calls `GainMapHEIC`.
    func testHDRIsOnByDefaultAndTheBatchTakesTheGainMapPath() {
        let sheet = model()
        XCTAssertEqual(sheet.preset.format, .heic, "HDR needs the HEIF container")
        XCTAssertEqual(sheet.preset.hdr?.enabled, true, "HDR defaults to on")
        // 109's default draft names ISO explicitly (it is the macOS 15+ spelling).
        XCTAssertEqual(sheet.preset.hdr?.gainMap, .iso)
        XCTAssertEqual(sheet.preset.hdr?.halfSize, true)
        XCTAssertEqual(sheet.preset.hdr?.headroom, .auto)

        XCTAssertNotNil(sheet.preset.exportOptions.hdr)
        XCTAssertEqual(sheet.preset.exportOptions.hdr?.enabled, true)
        XCTAssertNoThrow(try sheet.preset.validated())
    }

    /// §A + 163 + 216: JPEG carries a gain map too, so HEIC ↔ JPEG keeps the switch and the
    /// gain-map choices. TIFF/PNG cannot carry one, and since 216 the switch stays **on**: the kind
    /// drops to that container's default (PQ, 16-bit) instead of turning HDR off. An explicit "off"
    /// still survives every trip.
    func testHDRStaysOnAcrossEveryContainerAndItsKindFallsBackToTheFormatsDefault() {
        let sheet = model(writableUTIs: Set(ExportFormat.allCases.map { $0.utType.identifier }))
        sheet.hdrGainMap = .apple
        sheet.hdrHalfSize = true
        XCTAssertTrue(sheet.hdrEnabled)

        // HEIC → JPEG: same gain map, same half-size choice, and a JPEG preset validates.
        sheet.selectFormat(.jpeg)
        XCTAssertEqual(sheet.preset.format, .jpeg)
        XCTAssertTrue(sheet.hdrEnabled, "163: JPEG carries a gain map")
        XCTAssertEqual(sheet.preset.hdr?.enabled, true)
        XCTAssertEqual(sheet.hdrGainMap, .apple)
        XCTAssertTrue(sheet.hdrHalfSize)
        XCTAssertNotNil(sheet.preset.exportOptions.hdr, "the JPEG writer takes the gain-map path")
        XCTAssertNoThrow(try sheet.preset.validated())

        // …and JPEG → HEIC keeps both the switch and the menu choices.
        sheet.selectFormat(.heic)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.preset.hdr?.enabled, true)
        XCTAssertEqual(sheet.hdrGainMap, .apple)
        XCTAssertTrue(sheet.hdrHalfSize)
        XCTAssertEqual(sheet.preset.exportOptions.hdr?.gainMap, .apple)

        // 216: PNG has no auxiliary-image container, so the kind falls back to PNG's own default —
        // PQ at 16 bits — and HDR stays on instead of silently becoming an SDR export.
        sheet.selectFormat(.png)
        XCTAssertTrue(sheet.hdrEnabled, "216: HDR is on for every container")
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 16)
        XCTAssertNoThrow(try sheet.preset.validated())

        // HEIC remembers the gain map: coming back is not stuck on PQ.
        sheet.selectFormat(.heic)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.hdrKind, .gainMap)
        XCTAssertEqual(sheet.hdrGainMap, .apple)

        // The other order: the user turns HDR off, leaves HEIC, comes back — it stays off.
        sheet.setHDR(false)
        XCTAssertFalse(sheet.preset.hdr?.enabled ?? true)
        sheet.selectFormat(.jpeg)
        sheet.selectFormat(.heic)
        XCTAssertFalse(sheet.hdrEnabled, "a user who turned HDR off must not get it back for free")
        XCTAssertNil(sheet.preset.exportOptions.hdr)
        XCTAssertNoThrow(try sheet.preset.validated())

        // A second round trip must not resurrect the default either.
        sheet.selectFormat(.png)
        sheet.selectFormat(.heic)
        XCTAssertFalse(sheet.hdrEnabled)
    }

    /// §A + §3: the extra summary segment appears only while HDR is on and legal; off is 099 verbatim.
    func testSummaryShowsHDROnlyWhenTheToggleIsOn() {
        let sheet = model()
        sheet.selectionCount = 2
        sheet.preset = ExportSheetModel.defaultPreset

        // 钉死 iso 再断言文案，别让这条测试随 macOS 版本漂移。
        sheet.hdrGainMap = .iso
        XCTAssertTrue(sheet.summaryLine.contains("HDR ISO RGB"), sheet.summaryLine)
        sheet.hdrGainMap = .mono
        sheet.hdrHalfSize = true
        XCTAssertTrue(sheet.summaryLine.contains("HDR ISO mono 半尺寸"), sheet.summaryLine)

        sheet.setHDR(false)
        XCTAssertFalse(sheet.summaryLine.contains("HDR"))
        // 161 §1: the factory draft is now 原尺寸 (no long edge to report).
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 2 张 → HEIC · 8 位 · Display P3 · 原尺寸 · 重命名")
    }

    // MARK: - 106 layout (measured on the real hosted sheet)

    /// §B + 161 §6: the scroll region is the flexible one, and with no rows there is no results
    /// region at all — the form takes the space instead of leaving a blank strip above the footer.
    /// The sheet is a fixed 620×900: the seven 文件设置-era sections must keep scrolling (they want
    /// ~1078 pt), and the empty prompt stays on the footer's row.
    func testTheSevenSectionsGetTheirHeightAndTheEmptyResultsRegionIsGone() throws {
        let sheet = try host(height: 900)
        let formFrame = try frame(of: .form, in: sheet.host)
        let footerFrame = try frame(of: .footer, in: sheet.host)
        let status = try frame(of: .status, in: sheet.host)

        print(String(format: "layout · form %.1f · footer %.1f (footer maxY %.1f of %.1f)",
                     formFrame.height, footerFrame.height,
                     footerFrame.maxY, sheet.host.bounds.maxY))

        // 1. the form is not squeezed: much more than the old 320 pt clamp.
        XCTAssertGreaterThanOrEqual(formFrame.height, 600,
                                    "文件设置 那一组又被压扁了：form 只有 \(formFrame.height) pt")
        // 2. no empty results region grows a scroll view or a probe of its own.
        XCTAssertNil(descendants(of: sheet.host).compactMap { $0 as? ExportLayoutProbe }
            .first { $0.kind == .results }, "空态不该再有 results 区域")
        // 3. the form's bottom is close to the footer: the blank space is inside the scroll view.
        XCTAssertLessThanOrEqual(footerFrame.minY - formFrame.maxY, 12,
                                 "form 与 footer 之间夹了空白")
        // 4. the empty prompt is on the footer's row and outside any scroll view.
        XCTAssertEqual(status.midY, footerFrame.midY, accuracy: 2,
                       "空态文案必须和按钮同一行")
    }

    /// §A (the visible half): the HDR row keeps its height across format/toggle changes; the
    /// gain-map controls follow the toggle (109 replaced 106's menu with two segmented groups).
    /// 163 — JPEG is a gain-map container too, so the row stays lit there.
    func testTheHDRRowStaysPutAndTheGainMapControlsFollowTheFormat() throws {
        let sheet = model()
        let hosted = try host(height: 760, model: sheet)

        let heicRow = try frame(of: .hdrRow, in: hosted.host)
        XCTAssertGreaterThan(heicRow.height, 0, "the HDR row is in the sheet")
        XCTAssertTrue(sheet.hdrEnabled, "HEIC supports HDR")
        XCTAssertTrue(sheet.showsGainMapRows)

        sheet.selectFormat(.jpeg)
        pump(hosted.host)
        XCTAssertEqual(try frame(of: .hdrRow, in: hosted.host).height, heicRow.height,
                       accuracy: 0.5, "the row stays put")
        XCTAssertTrue(sheet.hdrEnabled, "163: JPEG carries a gain map")
        XCTAssertTrue(sheet.showsGainMapRows)
        XCTAssertFalse(sheet.showsToneMappingRow)

        sheet.setHDR(false)
        pump(hosted.host)
        XCTAssertEqual(try frame(of: .hdrRow, in: hosted.host).height, heicRow.height,
                       accuracy: 0.5, "the off state keeps the row height")
        XCTAssertFalse(sheet.showsGainMapRows)
        XCTAssertTrue(sheet.showsToneMappingRow)

        sheet.setHDR(true)
        pump(hosted.host)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertTrue(sheet.showsGainMapRows)
    }

    /// 163 §1.3 — choosing PQ/HLG writes the container's one legal depth in the same step, and the
    /// sheet never offers a second depth while that curve is selected.
    func testSelectingPQOrHLGLocksTheBitDepthAndUpdatesThePicker() throws {
        let sheet = model()
        XCTAssertEqual(sheet.hdrKind, .gainMap)
        XCTAssertEqual(sheet.bitDepths, [8, 10])

        sheet.setHDRKind(.pq)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 10)
        XCTAssertEqual(sheet.bitDepths, [10])
        XCTAssertNoThrow(try sheet.preset.validated())

        // A HEIF row moves to PNG: still PQ, now the lossless depth.
        sheet.selectFormat(.png)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 16)
        XCTAssertEqual(sheet.bitDepths, [16])
        XCTAssertNoThrow(try sheet.preset.validated())

        sheet.selectFormat(.heic)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 10)

        // JPEG has no PQ row: 216 keeps HDR on and drops to JPEG's own default (the gain map) at its
        // 8-bit base, instead of leaving an illegal preset behind.
        sheet.selectFormat(.jpeg)
        XCTAssertEqual(sheet.hdrKind, .gainMap)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.preset.bitDepth, 8)
        XCTAssertNoThrow(try sheet.preset.validated())
    }

    // MARK: - 216 default HDR per format

    /// 216 §1 — every container starts HDR on with its own default kind: the gain-map containers keep
    /// 163's auxiliary image, the lossless ones use PQ at 16 bits. The table is printed one row per
    /// format so the five-format comparison is in the test log, not inferred.
    func testEveryFormatStartsHDRWithItsOwnDefaultKind() {
        let allUTIs = Set(ExportFormat.allCases.map { $0.utType.identifier })
        var table: [String] = []
        for format in ExportFormat.allCases {
            let sheet = model(writableUTIs: allUTIs)
            sheet.selectFormat(format)
            XCTAssertEqual(sheet.preset.format, format)
            XCTAssertTrue(sheet.hdrEnabled, "\(format.rawValue): HDR must be on by default")
            XCTAssertEqual(sheet.hdrKind, format.defaultHDRKind, "\(format.rawValue) default kind")
            XCTAssertTrue(format.hdrIsOnByDefault, "\(format.rawValue) table row")
            if let locked = format.hdrTransferBitDepth(for: format.defaultHDRKind) {
                XCTAssertEqual(sheet.preset.bitDepth, locked,
                               "\(format.rawValue) default kind must lock its depth")
            }
            XCTAssertNoThrow(try sheet.preset.validated())
            table.append("216 · \(format.rawValue) → \(sheet.preset.format.rawValue)"
                         + ", kind \(sheet.hdrKind.rawValue), enabled \(sheet.hdrEnabled)"
                         + ", bits \(sheet.preset.effectiveBitDepth)")
        }
        print(table.joined(separator: "\n"))

        // The table itself, independent of the sheet: one place, every container named.
        XCTAssertEqual(ExportFormat.jpeg.defaultHDRKind, .gainMap)
        XCTAssertEqual(ExportFormat.heic.defaultHDRKind, .gainMap)
        XCTAssertEqual(ExportFormat.avif.defaultHDRKind, .gainMap)
        XCTAssertEqual(ExportFormat.tiff.defaultHDRKind, .pq)
        XCTAssertEqual(ExportFormat.png.defaultHDRKind, .pq)
        XCTAssertTrue(ExportFormat.allCases.allSatisfy(\.hdrIsOnByDefault))
        XCTAssertEqual(ExportFormat.tiff.hdrTransferBitDepth(for: ExportFormat.tiff.defaultHDRKind),
                       16)
        XCTAssertEqual(ExportFormat.png.hdrTransferBitDepth(for: ExportFormat.png.defaultHDRKind),
                       16)
    }

    /// 216 §2 — the degradation path is a *kind* change, never an off switch. The four-tuple is
    /// printed for each of the three switches the spec names.
    func testFormatSwitchDegradesToTheContainersOwnKindInsteadOfTurningHDROff() {
        let allUTIs = Set(ExportFormat.allCases.map { $0.utType.identifier })
        let sheet = model(writableUTIs: allUTIs)

        func tuple(_ label: String) {
            print("216 · \(label) → (\(sheet.preset.format.rawValue), \(sheet.hdrKind.rawValue),"
                  + " \(sheet.hdrEnabled), \(sheet.preset.effectiveBitDepth))")
        }

        // HEIC picks PQ explicitly: that is HEIC's remembered kind, at HEIF's 10-bit depth.
        sheet.setHDRKind(.pq)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 10)
        tuple("before")

        // HEIC(pq) → TIFF: still PQ, now lossless 16-bit — not off.
        sheet.selectFormat(.tiff)
        tuple("after selectFormat(.tiff)")
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 16)
        XCTAssertNoThrow(try sheet.preset.validated())

        // TIFF(pq) → JPEG: PQ is illegal there, so the kind drops to JPEG's own default (gain map)
        // and HDR stays on.
        sheet.selectFormat(.jpeg)
        tuple("after selectFormat(.jpeg)")
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.hdrKind, .gainMap)
        XCTAssertEqual(sheet.preset.bitDepth, 8)
        XCTAssertNoThrow(try sheet.preset.validated())

        // Back to HEIC: the container's own memory (PQ, the user's pick) wins over JPEG's gain map.
        sheet.selectFormat(.heic)
        tuple("after selectFormat(.heic)")
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 10)
        XCTAssertNoThrow(try sheet.preset.validated())
    }

    /// 216 §2 — TIFF's automatic PQ is a fallback, not a choice: HEIC → TIFF → HEIC returns to HEIC's
    /// remembered gain map instead of inheriting PQ.
    func testTIFSsAutomaticPQDoesNotStickToHEIC() {
        let allUTIs = Set(ExportFormat.allCases.map { $0.utType.identifier })
        let sheet = model(writableUTIs: allUTIs)
        XCTAssertEqual(sheet.hdrKind, .gainMap)

        sheet.selectFormat(.tiff)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertTrue(sheet.hdrEnabled)

        sheet.selectFormat(.heic)
        XCTAssertEqual(sheet.hdrKind, .gainMap)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.preset.bitDepth, 10,
                       "TIFF's 16-bit storage clamps to HEIC's legal 10-bit gain-map base")
    }

    /// 216 §4 — a loaded preset replays its switch for every container, not only HEIC, and its kind
    /// is remembered for that container. A saved TIFF+PQ preset comes back as TIFF+PQ.
    func testLoadedPresetReplaysHDRForEveryFormat() {
        let sheet = model()
        sheet.preset = ExportPreset(name: "TIFF HDR", format: .tiff, bitDepth: 16,
                                    hdr: HDRExport(kind: .pq))
        XCTAssertTrue(sheet.savePreset(named: "TIFF HDR"))
        sheet.loadPreset(named: "TIFF HDR")
        XCTAssertEqual(sheet.preset.format, .tiff)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.hdrKind, .pq)
        XCTAssertEqual(sheet.preset.bitDepth, 16)
        XCTAssertNoThrow(try sheet.preset.validated())

        // A TIFF preset with HDR explicitly off stays off on load, and switching to another
        // container does not turn it back on.
        sheet.preset = ExportPreset(name: "TIFF SDR", format: .tiff, bitDepth: 16,
                                    hdr: HDRExport(enabled: false))
        XCTAssertTrue(sheet.savePreset(named: "TIFF SDR"))
        sheet.loadPreset(named: "TIFF SDR")
        XCTAssertFalse(sheet.hdrEnabled)
        sheet.selectFormat(.heic)
        XCTAssertFalse(sheet.hdrEnabled)
    }

    // MARK: - 163 §1.6 half-size even-pixel hint

    /// The warning is conditional: odd output shows the exact crop, even output builds no view at
    /// all, and the full-size switch removes it. `predictedSizeText` agrees with the crop.
    func testHalfSizeCropHintAppearsOnlyForOddOutput() {
        let sheet = model()
        XCTAssertEqual(sheet.hdrKind, .gainMap)
        sheet.selectionContents = [ImageSize(width: 6001, height: 4001)]
        XCTAssertEqual(sheet.halfSizeCropHint,
                       "半尺寸需要偶数像素：当前 6001×4001，将裁到 6000×4000（右/下各 1 px）")
        XCTAssertEqual(sheet.predictedSizeText(native: ImageSize(width: 6001, height: 4001)),
                       "6000×4000")

        sheet.selectionContents = [ImageSize(width: 6000, height: 4000)]
        XCTAssertNil(sheet.halfSizeCropHint, "even output must not leave an empty line")
        XCTAssertEqual(sheet.predictedSizeText(native: ImageSize(width: 6000, height: 4000)),
                       "6000×4000")

        sheet.selectionContents = [ImageSize(width: 6001, height: 4001)]
        sheet.hdrHalfSize = false
        XCTAssertNil(sheet.halfSizeCropHint, "full-size export keeps 6001×4001")
        XCTAssertEqual(sheet.predictedSizeText(native: ImageSize(width: 6001, height: 4001)),
                       "6001×4001")

        sheet.hdrHalfSize = true
        sheet.setHDRKind(.hlg)
        XCTAssertNil(sheet.halfSizeCropHint, "only a gain map has a half-size map")
    }

    // MARK: - hosting helpers

    private struct Hosted {
        let host: NSHostingView<ExportSheetView>
        let window: NSWindow
    }

    private func host(height: CGFloat) throws -> Hosted {
        try host(height: height, model: model())
    }

    private func host(height: CGFloat, model sheet: ExportSheetModel) throws -> Hosted {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ExportSheetView(model: sheet))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        return Hosted(host: host, window: window)
    }

    private func pump(_ host: NSHostingView<ExportSheetView>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func probe(of kind: ExportLayoutProbe.Kind,
                       in host: NSView) throws -> ExportLayoutProbe {
        let match = descendants(of: host)
            .compactMap { $0 as? ExportLayoutProbe }
            .first { $0.kind == kind }
        return try XCTUnwrap(match, "no \(kind.rawValue) probe in the hosted sheet")
    }

    private func frame(of kind: ExportLayoutProbe.Kind, in host: NSView) throws -> NSRect {
        let probe = try probe(of: kind, in: host)
        return probe.convert(probe.bounds, to: host)
    }
}
