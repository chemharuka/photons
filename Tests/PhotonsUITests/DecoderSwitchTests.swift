import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 解码模型切换 — 选完版本**立即重算**，四轴随之回默认，一条历史 (owner, 2026-10-27).
///
/// The user's report was not "the picker does not stick" but **"选完画面不动，拖一下滑杆才重算"**, and
/// the second half of it — "而且此时可能因为降噪等滑块处于不允许的状态，导致回退" — was the same fact seen
/// from the panel: the four amounts were carried across a switch to a decoder that cannot honour two of
/// them.
///
/// Two defects, both closed here, both measured on the **live** path (a real `CatalogSession` opened on
/// a real library, a real `LoupeController` with its automatic render loop on — no `makeFrame` hand
/// calls, because the claim is "no slider has to be touched", which only the live loop can honour):
///
///  1. **The rung identity was blind to the decoder version.** `DecodeInputs.key` had `ver=` from the
///     beginning, but the ladder / queue / `isCurrentPhoto` identity comes from
///     `DecodeInputs.appending(to:)`, which appended only the white balance and the detail amounts. A
///     `9.dng` request therefore landed in the **same slot** as the resident v8 buffer: the edit frame
///     found "its" rung already resident, painted the v8 pixels, and `session.capabilities` — fed by the
///     presented frame — kept reporting v8. The only input that could dislodge it was an unrelated
///     decode input, i.e. a detail slider (which appends `dt=…`): exactly the workaround the user found.
///  2. **The pick kept the four amounts.** Greyed is not zeroed, so a v9 document carried a 色彩降噪 of
///     70 that the decoder silently vetoed (`applyDetail`), and the panel sat on a number that no longer
///     did anything. The owner's rule is the fix: **改解码版本 = 四轴强制回该版本的默认值**
///     (`detailSettings = .identity`, i.e. all four at the body's own baseline), in the **same** edit as
///     the version, so one ⌘Z takes back both.
///
/// Every claim below is a number: `RAWDecoder.decodeCounts()` (real ImageIO, per rung),
/// `FrameResult.displayHash` (SHA-256 of the presented rgba16f texture), `session.capabilities` (Apple's
/// read-back), the four `DetailSettings` fields, and `session.history.count`. The "was it recomputed?"
/// gate is `settle`: the frame on screen must carry the document's own `editRevision` — nothing in this
/// suite moves a slider, the camera or the zoom to get there.
///
/// The RAW fixture is the user's own photo and is not vendored: set `PHOTONS_TEST_RAW` or the suite
/// skips (same convention as `WhiteBalanceSectionTests` / `DecoderModelCardTests`).
@MainActor
final class DecoderSwitchTests: XCTestCase {

    private var workDir: URL!
    /// The controller holds its session **weakly** and the decoder callbacks outlive the test body:
    /// without this the session would be gone mid-frame.
    private var keepAlive: [AnyObject] = []

    /// Device pixels; the canvas is half that in points, exactly as in the other loupe suites.
    private static let viewport = NSSize(width: 900, height: 600)

    /// The four amounts a user has been dragging — 色彩降噪 and 细节 are exactly the two a v9 decoder
    /// refuses to assign, which is why they must not survive the switch.
    private static let amounts = DetailSettings(luminanceNR: 40, colorNR: 70, sharpness: 60, detail: 30)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-decswitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - A. 选完版本立即重算（不碰滑杆）

    /// The acceptance, first half: **the pick alone develops the picture.**
    ///
    /// Between `decoderVersion("9.dng")` and the assertions there is no slider, no camera move, no
    /// zoom, no hand-made frame: only the run loop. What the numbers have to say:
    ///
    ///   · `decodeCounts[0.5]` **+1** and `[1.0]` **+1** — one fresh development of each resident rung,
    ///     which is what a version switch costs (the ladder develops the preview rung first so the
    ///     canvas is never dark for a 60 MP decode, then the full one). Total +2, presented rung +1;
    ///   · `session.capabilities` — Apple's **read-back** — moves to `9.dng`, `requestedVersion` too,
    ///     and the four rows are inert exactly where v9 does not honour them;
    ///   · the presented frame's `displayHash` differs from the v8 frame's (two hashes printed);
    ///   · `lastPresentedScale` is unchanged: 换版本换的是解码器，不是相机.
    func testPickingAVersionRedevelopesWithNoSliderMotion() throws {
        let url = try fixtureURL()
        let harness = try makeHarness(url: url, startingVersion: nil)
        let session = harness.session, loupe = harness.loupe, resets = harness.resets
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        // ── v8 baseline: the document asks for nothing, the canvas has caught up with it
        XCTAssertNil(session.edit.decoderVersion)
        let v8 = try settle(loupe, session: session)
        let hash8 = try XCTUnwrap(v8.hash, "the v8 frame produced no hash")
        let scale8 = loupe.lastPresentedScale
        let counts8 = RAWDecoder.decodeCounts()
        XCTAssertEqual(v8.effectiveVersion, "8", "the default decode is Apple's default (v8)")

        // ── the pick, and **nothing else**
        XCTAssertTrue(resets.decoderVersion("9.dng", offered: offered),
                      "picking a version the file offers must write the document")
        XCTAssertEqual(session.edit.decoderVersion, "9.dng")
        let v9 = try settle(loupe, session: session)
        let hash9 = try XCTUnwrap(v9.hash, "the v9 frame produced no hash")
        let counts9 = RAWDecoder.decodeCounts()

        let perRung = counts9.map { "\($0.key):\($0.value)" }.sorted().joined(separator: " ")
        print("SWITCH v8 \(hash8.prefix(16)) · v9 \(hash9.prefix(16)) · counts \(counts8) → \(counts9)"
              + " · scale \(String(describing: scale8)) → \(String(describing: loupe.lastPresentedScale))"
              + " · caps \(v9.effectiveVersion) · \(perRung)")

        // ① one fresh development of each resident rung — the *presented* one included
        XCTAssertEqual(counts9[DecodeLadder.previewScale], (counts8[DecodeLadder.previewScale] ?? 0) + 1,
                       "the preview rung the canvas shows was not developed again: \(perRung)")
        XCTAssertEqual(counts9[DecodeLadder.fullScale], (counts8[DecodeLadder.fullScale] ?? 0) + 1,
                       "the full rung was not developed again: \(perRung)")
        XCTAssertGreaterThan(counts9.values.reduce(0, +), counts8.values.reduce(0, +),
                             "选版本没有触发任何解码")

        // ② Apple's read-back, not the request
        XCTAssertEqual(v9.effectiveVersion, "9.dng", "生效版本必须是 9.dng，不是 v8")
        XCTAssertEqual(session.capabilities?.requestedVersion, "9.dng")
        XCTAssertEqual(session.capabilities?.downgraded, false)

        // ③ the four rows follow the **read-back**, so they are inert the moment the frame lands
        let rows = Self.rowStates(session: session, requested: "9.dng", document: "9.dng")
        print("SWITCH rows under v9: \(rows.sorted { $0.key < $1.key })")
        XCTAssertEqual(rows, [DetailAxis.luminanceNR.title: true, DetailAxis.colorNR.title: false,
                              DetailAxis.detail.title: false, DetailAxis.sharpness.title: true],
                       "换版本后 isEnabled 必须立刻反映新版本（v9：降噪/锐化可用，色彩降噪/细节置灰）")

        // ④ the pixels really moved
        XCTAssertNotEqual(hash9, hash8, "选完 v9 帧像素没变 —— 新去马赛克没有跑")

        // ⑤ the camera did not
        XCTAssertEqual(loupe.lastPresentedScale, scale8, "a decoder switch must not move the camera")
    }

    // MARK: - B. 四轴强制回默认，一条历史

    /// The acceptance, second half: **the four amounts do not survive a version switch**, and they go
    /// back together with the version in a single history entry.
    ///
    /// The amounts are set to values a *v9* decoder cannot honour (色彩降噪 70 / 细节 30): the old
    /// document kept them and relied on the veto, which is the "回退" the user saw. After the pick every
    /// field must be `nil` (the body's baseline, **not** 0 — colour NR's default on a Leica is 50), and
    /// one ⌘Z must bring back the version *and* the amounts.
    func testThePickForcesTheFourAxesBackToTheirDefaultsInOneEntry() throws {
        let url = try fixtureURL()
        let harness = try makeHarness(url: url, startingVersion: nil)
        let session = harness.session, resets = harness.resets
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        session.applyEdit { $0.detailSettings = Self.amounts }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let historyBefore = session.history.count
        let identityBefore = session.edit.decodeInputs.appending(to: "photo")

        XCTAssertTrue(resets.decoderVersion("9.dng", offered: offered))

        // ① the document: version **and** all four fields
        XCTAssertEqual(session.edit.decoderVersion, "9.dng")
        XCTAssertTrue(session.edit.detailSettings.isIdentity,
                      "换版本没有把四轴压回默认值：\(session.edit.detailSettings.summary)")
        XCTAssertNil(session.edit.detailSettings.luminanceNR, "降噪 must be nil (the body's baseline)")
        XCTAssertNil(session.edit.detailSettings.colorNR, "色彩降噪 must be nil, not 70")
        XCTAssertNil(session.edit.detailSettings.detail, "细节 must be nil, not 30")
        XCTAssertNil(session.edit.detailSettings.sharpness, "锐化 must be nil, not 60")
        XCTAssertEqual(session.edit.detailSettings.position(.colorNR, in: .measured), 50,
                       "屏幕上是机身的默认位置 50，不是 0")

        // ② one entry, not two
        XCTAssertEqual(session.history.count, historyBefore + 1,
                       "一次版本切换必须是 history +1，不是 +2")
        XCTAssertEqual(session.history.currentSnapshot?.label, "解码模型")

        // ③ the rung identity moved with the version (this is the recompute, at the key level)
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo|ver=9.dng")
        XCTAssertNotEqual(session.edit.decodeInputs.appending(to: "photo"), identityBefore)

        // ④ one ⌘Z takes back both halves — the two fields, before and after
        let versionAfter = session.edit.decoderVersion
        let amountsAfter = session.edit.detailSettings
        XCTAssertTrue(session.undo())
        print("SWITCH undo: decoderVersion \(versionAfter ?? "nil") → "
              + "\(session.edit.decoderVersion ?? "nil") · detailSettings "
              + "\(amountsAfter.summary) → \(session.edit.detailSettings.summary)")
        XCTAssertNil(session.edit.decoderVersion, "⌘Z 必须把版本一起退回")
        XCTAssertEqual(session.edit.detailSettings, Self.amounts, "⌘Z 必须把四轴一起退回（同一条历史）")
    }

    // MARK: - C. 等效性：v8 文档 → v9 的画面 == 直接以 v9 打开

    /// The proof that a **new demosaic** ran — and that the switch threw away the amounts — rather than
    /// the old rung being relabelled: a v8 document that has been *adjusted* (four amounts set) ends up
    /// pixel-identical to a document that asked for `9.dng` from its first frame. Two independent
    /// sessions, two independent ladders, one hash.
    func testSwitchingToV9ProducesTheSamePixelsAsOpeningAtV9() throws {
        let url = try fixtureURL()

        let switched = try makeHarness(url: url, startingVersion: nil)
        let session = switched.session
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        // ── a v8 document as the user leaves it: four sliders moved
        let pristine = try settle(switched.loupe, session: session)
        session.applyEdit { $0.detailSettings = Self.amounts }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let adjusted = try settle(switched.loupe, session: session)
        XCTAssertNotEqual(adjusted.hash, pristine.hash,
                          "the four amounts moved no v8 pixel — the equivalence below would prove nothing")

        // ── the switch, then the comparison
        XCTAssertTrue(switched.resets.decoderVersion("9.dng", offered: offered))
        let afterSwitch = try settle(switched.loupe, session: session)

        let direct = try makeHarness(url: url, startingVersion: "9.dng")
        let openedAtV9 = try settle(direct.loupe, session: direct.session)

        print("SWITCH equivalence · v8+四轴 \((adjusted.hash ?? "nil").prefix(16))"
              + " · v8→v9 \((afterSwitch.hash ?? "nil").prefix(16))"
              + " · opened at v9 \((openedAtV9.hash ?? "nil").prefix(16))"
              + " · scales \(String(describing: switched.loupe.lastPresentedScale))"
              + "/\(String(describing: direct.loupe.lastPresentedScale))")

        XCTAssertEqual(afterSwitch.effectiveVersion, "9.dng")
        XCTAssertEqual(openedAtV9.effectiveVersion, "9.dng")
        XCTAssertEqual(switched.loupe.lastPresentedScale, direct.loupe.lastPresentedScale,
                       "the two frames must be compared at the same rung")
        XCTAssertEqual(afterSwitch.hash, openedAtV9.hash,
                       "v8→v9 的画面与直接以 v9 打开的画面不同 —— 不是新去马赛克，或四轴没有清")
        XCTAssertNotEqual(afterSwitch.hash, adjusted.hash, "v9 的画面与 v8+四轴 的画面相同 —— 没重算")
    }

    // MARK: - D. 再选回 8

    /// Back to the default: **+1 development per rung again**, the four amounts still at their
    /// defaults, and the four rows live again (a v8 decode honours all four).
    func testPickingEightAgainRedevelopesAndReEnablesAllFourRows() throws {
        let url = try fixtureURL()
        let harness = try makeHarness(url: url, startingVersion: "9.dng")
        let session = harness.session, loupe = harness.loupe, resets = harness.resets
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        let atV9 = try settle(loupe, session: session)
        XCTAssertEqual(atV9.effectiveVersion, "9.dng")
        let rowsV9 = InspectorView.detailAxes(capabilities: session.capabilities,
                                              requested: "9.dng", document: "9.dng")
        XCTAssertEqual(rowsV9.nr, true, "v9 下降噪仍然可用")
        XCTAssertEqual(rowsV9.cnr, false, "v9 下色彩降噪必须置灰")
        XCTAssertEqual(rowsV9.detail, false, "v9 下细节必须置灰")
        XCTAssertEqual(rowsV9.sharpness, true, "v9 下锐化仍然可用")
        let countsV9 = RAWDecoder.decodeCounts()

        XCTAssertTrue(resets.decoderVersion("8", offered: offered))
        XCTAssertNil(session.edit.decoderVersion, "`8` is stored as nil — the untouched decode")
        XCTAssertTrue(session.edit.detailSettings.isIdentity, "四轴仍然停在默认值")
        let atV8 = try settle(loupe, session: session)
        let countsV8 = RAWDecoder.decodeCounts()
        let rowsV8 = Self.rowStates(session: session, requested: nil, document: nil)

        print("SWITCH back to 8 · counts \(countsV9) → \(countsV8)"
              + " · effective \(atV8.effectiveVersion) · rows \(rowsV8.sorted { $0.key < $1.key })")

        XCTAssertEqual(countsV8[DecodeLadder.previewScale], (countsV9[DecodeLadder.previewScale] ?? 0) + 1)
        XCTAssertEqual(countsV8[DecodeLadder.fullScale], (countsV9[DecodeLadder.fullScale] ?? 0) + 1)
        XCTAssertEqual(atV8.effectiveVersion, "8")
        XCTAssertEqual(rowsV8, [DetailAxis.luminanceNR.title: true, DetailAxis.colorNR.title: true,
                                DetailAxis.detail.title: true, DetailAxis.sharpness.title: true],
                       "回到 v8 后四根都必须重新可用（读的是解码回读的 isSupported，不是版本表）")
        XCTAssertNotEqual(atV8.hash, atV9.hash, "回到 v8 必须换回 v8 的画面")
    }

    // MARK: - E. 反证（这里跑的是**旧**写法，所以红的就是那条断言）

    /// **反证一：四轴不清 = 用户在 v9 下看见一个不被支持的 70。**
    ///
    /// The pick exactly as it was spelled before the fix (`applyEdit { $0.decoderVersion = … }` and
    /// nothing else), run against the same document. It is here so the acceptance assertion
    /// `detailSettings == .identity` has a documented way to go red: on this document it is `70`, and
    /// the decode key still asks for it — the "回退" the user described is this document plus
    /// `applyDetail`'s veto.
    func test反证_TheOldPickKeepsAnAmountV9CannotHonour() throws {
        let session = CatalogSession()
        session.applyEdit { $0.detailSettings = Self.amounts }
        XCTAssertTrue(session.commitEdit(label: "拖动"))

        // The pre-fix spelling, verbatim:
        session.applyEdit { $0.decoderVersion = "9.dng" }
        XCTAssertTrue(session.commitEdit(label: "解码模型"))

        XCTAssertEqual(session.edit.decoderVersion, "9.dng")
        XCTAssertFalse(session.edit.detailSettings.isIdentity,
                       "the old path leaves the four amounts in a v9 document — that is the defect")
        XCTAssertEqual(session.edit.detailSettings.colorNR, 70)
        XCTAssertTrue(session.edit.decodeInputs.key.contains("dt=nr40,c70,s60,d30"),
                      "…and the decode key still asks for them: \(session.edit.decodeInputs.key)")

        // …while the shipped pick, on the same document, clears them (the assertion that must go red).
        let shipped = CatalogSession()
        shipped.applyEdit { $0.detailSettings = Self.amounts }
        XCTAssertTrue(shipped.commitEdit(label: "拖动"))
        XCTAssertTrue(PanelResets(session: shipped).decoderVersion("9.dng", offered: ["8", "9.dng"]))
        XCTAssertTrue(shipped.edit.detailSettings.isIdentity)
        print("SWITCH 反证① old pick → \(session.edit.detailSettings.summary)"
              + " · shipped pick → \(shipped.edit.detailSettings.summary)")
    }

    /// **反证二：版本不进 rung identity = 画面不动。**
    ///
    /// The identity is the string the ladder, the decode queue and `isCurrentPhoto` compare. The
    /// pre-fix spelling is reconstructed as a literal here — `photo` — and compared with what the
    /// document produces now. On the old code the two were **equal**, which is why a v9 request was
    /// answered by the resident v8 buffer (recorded control run: `decodeCounts` stayed
    /// `[0.5: 1, 1.0: 1]`, both hashes `983d7d51…`, `caps` still v8).
    func test反证_TheVersionBlindIdentityIsNotWhatTheDocumentProducesNow() {
        var v9 = EditModel.neutral
        v9.decoderVersion = "9.dng"
        let blind = "photo"                                   // the pre-fix `appending(to:)` output
        let now = v9.decodeInputs.appending(to: "photo")
        XCTAssertNotEqual(now, blind, "the version must be part of the rung identity: \(now)")
        XCTAssertEqual(now, "photo|ver=9.dng")
        XCTAssertEqual(EditModel.neutral.decodeInputs.appending(to: "photo"), blind,
                       "…and the default document must still append nothing (byte-identical keys)")
        print("SWITCH 反证② rung identity: v8 → \(blind) · v9 → \(now)")
    }

    // MARK: - helpers

    private struct Harness {
        let session: CatalogSession
        let loupe: LoupeController
        let resets: PanelResets
    }

    /// A frame that is on the canvas, read back through the loupe's own record of the present.
    private struct Settled {
        let hash: String?
        let effectiveVersion: String?
    }

    /// A real library (a `.reference` root on the fixture's own folder — nothing is copied), the photo
    /// anchored in 单图 mode, and a loupe whose **automatic** render loop is on: every frame in this
    /// suite is produced by the shipping path, triggered by the document change alone.
    private func makeHarness(url: URL, startingVersion: String?) throws -> Harness {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let root = try catalog.ensureRoot(for: url.deletingLastPathComponent(), mode: .reference)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let assetID = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(assetID)', '\(root.id)', '\(url.lastPathComponent)', '\(url.lastPathComponent)',
                        'dng', 'raw', \(size), \(mtime), '\(UUID().uuidString)',
                        9520, 6336, 'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-10-27T00:00:00Z', 0)
                """)
        }

        let session = CatalogSession()
        try session.open(package)
        session.selectOnly(assetID)
        session.mode = .loupe
        session.loadEditForAnchor()
        if let startingVersion {
            session.applyEdit { $0.decoderVersion = startingVersion }
            XCTAssertTrue(session.commitEdit(label: "打开时指定解码模型"))
        }

        let loupe = LoupeController(session: session)
        loupe.hashesFrames = true
        loupe.collectsHistogram = false
        loupe.view.frame = NSRect(origin: .zero, size: Self.viewport)
        loupe.canvasView.frame = NSRect(origin: .zero, size: Self.viewport)
        loupe.view.layoutSubtreeIfNeeded()

        keepAlive.append(session)
        keepAlive.append(loupe)
        return Harness(session: session, loupe: loupe,
                       resets: PanelResets(session: session, loupe: loupe))
    }

    /// Wait until the **canvas has caught up with the document**: the presented frame carries the
    /// document's current `editRevision`, and it is the full-rung one (so two harnesses are compared at
    /// the same scale). This is the machine-readable form of 「选完就重算」 — nothing in here touches the
    /// document, the camera or the zoom.
    private func settle(_ loupe: LoupeController, session: CatalogSession,
                        timeout: TimeInterval = 120) throws -> Settled {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = loupe.lastFrame, frame.editRevision == session.editRevision,
               loupe.lastPresentedScale == DecodeLadder.fullScale {
                return Settled(hash: frame.displayHash,
                               effectiveVersion: frame.capabilities?.effectiveVersion)
            }
            CropUITestSupport.pump(0.05)
        }
        XCTFail("the canvas never caught up with the document (rev \(session.editRevision)) in "
                + "\(Int(timeout))s · frame rev \(loupe.lastFrame?.editRevision ?? -1)"
                + " · caps \(loupe.lastFrame?.capabilities?.summary ?? "nil")"
                + " · scale \(String(describing: loupe.lastPresentedScale))"
                + " · decodes \(RAWDecoder.decodeCounts())")
        return Settled(hash: loupe.lastFrame?.displayHash,
                       effectiveVersion: loupe.lastFrame?.capabilities?.effectiveVersion)
    }

    private static func rowStates(session: CatalogSession, requested: String?,
                                  document: String?) -> [String: Bool] {
        let axes = InspectorView.detailAxes(capabilities: session.capabilities,
                                            requested: requested, document: document)
        return Dictionary(uniqueKeysWithValues: DetailAxis.panelOrder.map { ($0.title, axes.isEnabled($0)) })
    }

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }
}
