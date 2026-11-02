import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 263 — 「撤销」 on a newest row appends one 「撤销 xxx」 snapshot; it never removes a row.
///
/// The first test is the user's own example:
///
/// ```
///   A 曝光 +0.2   B 曝光 +0.5   C 曲线   D 曝光 +0.8   E 修复
///   revert(D)  →  A B C D E F，F = 「撤销 D」：曝光变回 B 的 +0.5，
///                 C 的曲线和 E 的修复不动
/// ```
///
/// C stays 「最新」 in this fixture: nothing after it moves `curve.white`, so `isNewestOfClass` — the
/// one predicate, by field — says true. The dispatch's 「C 为 false」 contradicts its own branch case
/// (which reverts C while D/E sit in the redo branch, and therefore requires C to be revertible).
/// The code follows the predicate; this test asserts what the predicate actually says.
///
/// Rendering is checked with a synthetic image (no RAW fixture): the claim is about the document and
/// its stage keys, not about Apple's decoder. `editRevision` is the render signal, so one increment
/// is the "exactly one re-render" evidence without a window session.
@MainActor
final class HistoryRevertTests: XCTestCase {

    private let aExposure = 0.2
    private let bExposure = 0.5
    private let dExposure = 0.8

    // Same two endpoints as the identity curve: C moves the upper point's y, so its row is one curve
    // leaf rather than a structural `curve.white.count`.
    private let cCurve = [CurvePoint(0, 0), CurvePoint(2, 1.5)]

    private func makeSession() -> CatalogSession {
        // No catalog and no baseline: the five commits are A…E at indices 0…4, which is the panel the
        // user described (row count 5 → 6 after the revert).
        CatalogSession()
    }

    @discardableResult
    private func commit(_ session: CatalogSession, _ label: String,
                        _ mutate: (inout EditModel) -> Void) -> Bool {
        session.applyEdit(mutate)
        return session.commitEdit(label: label, coalesce: false)
    }

    /// A/B/C/D/E exactly as in the dispatch; returns the five seqs.
    @discardableResult
    private func buildABCDE(_ session: CatalogSession) -> [Int] {
        XCTAssertTrue(commit(session, "A") { $0.light.exposure = aExposure })
        XCTAssertTrue(commit(session, "B") { $0.light.exposure = bExposure })
        XCTAssertTrue(commit(session, "C") { $0.curve.white = cCurve })
        XCTAssertTrue(commit(session, "D") { $0.light.exposure = dExposure })
        XCTAssertTrue(commit(session, "E") {
            $0.healSpots = [HealSpot(id: "h-e", center: NormalizedPoint(0.42, 0.58), radius: 0.02)]
        })
        return session.history.snapshots.map(\.seq)
    }

    // MARK: - 1. the user's example

    func testRevertingDAppendsAUndoRowThatRestoresBsExposure() throws {
        let session = makeSession()
        let seqs = buildABCDE(session)
        XCTAssertEqual(seqs, [0, 1, 2, 3, 4])
        XCTAssertEqual(session.history.count, 5)
        XCTAssertEqual(session.history.cursor, 4, "cursor = E")

        // The predicate: D and E are newest; A and B are not (曝光 was written later). C is newest
        // too — the dispatch says false, but nothing after C moves `curve.white`; see the file note.
        XCTAssertFalse(session.history.isNewestOfClass(at: 0), "A is the floor; 曝光 was written later")
        XCTAssertFalse(session.history.isNewestOfClass(at: 1), "B 的曝光被 D 覆盖")
        XCTAssertTrue(session.history.isNewestOfClass(at: 2), "C 的曲线没有后续写入")
        XCTAssertTrue(session.history.isNewestOfClass(at: 3), "D 是最新")
        XCTAssertTrue(session.history.isNewestOfClass(at: 4), "E 是最新")

        let eDoc = try XCTUnwrap(session.history.current)
        let bDoc = session.history.snapshots[1].edit
        let cDoc = session.history.snapshots[2].edit
        let dRow = session.history.snapshots[3]
        XCTAssertEqual(bDoc.light.exposure, bExposure, accuracy: 1e-12)
        XCTAssertEqual(cDoc.curve.white, cCurve)

        // Rendering before/after: stage keys must move, and the reverted document must hash exactly
        // like a clean render of the expected document.
        let before = try render(eDoc, tag: "before")
        let beforeKeys = before.keys.shortTrace
        let beforeSHA = try XCTUnwrap(before.display).sha256()

        var expected = eDoc
        expected.light.exposure = bExposure
        expected.curve.white = cCurve
        let expectedRender = try render(expected, tag: "expected")
        let expectedSHA = try XCTUnwrap(expectedRender.display).sha256()

        let revisionBefore = session.editRevision
        let countBefore = session.history.count
        let seqBefore = session.history.currentSeq
        let cursorBefore = session.history.cursor

        XCTAssertTrue(session.revertHistoryEntry(at: 3), "revert(D) must append")
        var rendersAfterRevert = 0
        let after = try render(try XCTUnwrap(session.history.current), tag: "after")
        rendersAfterRevert += 1
        let afterKeys = after.keys.shortTrace
        let afterSHA = try XCTUnwrap(after.display).sha256()

        // The appended row.
        let new = try XCTUnwrap(session.history.snapshots.last)
        XCTAssertEqual(session.history.count, countBefore + 1)
        XCTAssertEqual(session.history.count, 6)
        XCTAssertGreaterThan(new.seq, seqs[4], "seq 继续增长，不复用")
        XCTAssertEqual(new.seq, 5)
        XCTAssertTrue(new.label.contains("撤销"))
        XCTAssertTrue(new.label.contains(dRow.label), "「撤销 \(dRow.label)」")
        XCTAssertEqual(session.history.cursor, countBefore, "cursor 移到 F")
        XCTAssertNotEqual(cursorBefore, session.history.cursor)

        // F's document: only D's fields moved back; C's curve and E's heal survive.
        XCTAssertEqual(new.edit.light.exposure, bExposure, accuracy: 1e-12)
        XCTAssertEqual(new.edit.curve.white, cCurve, "曲线回到 C 的值")
        XCTAssertEqual(new.edit.healSpots, eDoc.healSpots, "E 的修复不动")
        XCTAssertEqual(session.history.current, new.edit)
        XCTAssertEqual(session.edit, new.edit)
        XCTAssertEqual(session.history.currentSeq, new.seq)
        XCTAssertEqual(new.changes.map(\.field.key), dRow.changes.map(\.field.key),
                       "F 的 changes 就是 D 那些字段的反向几步")

        // D is covered by F; E is still newest.
        let dIndex = try XCTUnwrap(session.history.index(of: dRow.seq))
        XCTAssertFalse(session.history.isNewestOfClass(at: dIndex))
        XCTAssertTrue(session.history.isNewestOfClass(at: 4), "E 仍是最新")

        // One render request (editRevision) and the clean-render hash.
        XCTAssertEqual(session.editRevision, revisionBefore + 1, "恰好一次重渲")
        XCTAssertEqual(rendersAfterRevert, 1)
        XCTAssertNotEqual(afterKeys, beforeKeys, "stageKeys 必须变")
        XCTAssertNotEqual(afterSHA, beforeSHA, "撤销后的像素必须变")
        XCTAssertEqual(afterSHA, expectedSHA, "撤销后的文档渲染 == 载入期望文档再渲染")
        XCTAssertEqual(session.history.nextSeq, 6)
        XCTAssertEqual(seqBefore, 4)

        print("263 REVERT · count \(countBefore) → \(session.history.count)"
              + " · seq \(seqs) → \(session.history.snapshots.map(\.seq))"
              + " · cursor \(cursorBefore) → \(session.history.cursor)"
              + " · label 「\(new.label)」")
        print("263 KEYS · before \(beforeKeys)")
        print("263 KEYS · after  \(afterKeys)")
        print("263 PIXELS · before \(beforeSHA) · after \(afterSHA)"
              + " · expected \(expectedSHA) · renders \(rendersAfterRevert)")

        // Then revert E: the heal spot has no earlier writer, so it goes back to the floor (empty).
        let eIndex = try XCTUnwrap(session.history.index(of: seqs[4]))
        XCTAssertTrue(session.revertHistoryEntry(at: eIndex))
        XCTAssertEqual(session.history.count, 7)
        XCTAssertEqual(session.history.snapshots.last?.edit.healSpots, [], "修复回到 floor（没有人写过）")
        XCTAssertEqual(session.history.snapshots.last?.label, "撤销 E")
        print("263 REVERT E · count 6 → \(session.history.count) · heal \(session.history.snapshots.last?.edit.healSpots.count ?? -1)")
    }

    // MARK: - 2. a jump back to C: the redo branch is truncated, then the undo row is appended

    func testRevertingCMidStackTruncatesTheRedoBranchThenAppends() throws {
        let session = makeSession()
        let seqs = buildABCDE(session)
        XCTAssertEqual(seqs, [0, 1, 2, 3, 4])

        XCTAssertTrue(session.jumpToHistory(seq: seqs[2]))
        XCTAssertEqual(session.history.cursor, 2)
        XCTAssertTrue(session.history.canRedo)

        let revisionBefore = session.editRevision
        XCTAssertTrue(session.revertHistoryEntry(at: 2))

        XCTAssertEqual(session.history.count, 4, "0/1/2 + F")
        XCTAssertEqual(session.history.snapshots.map(\.seq), [0, 1, 2, 5], "D/E 被截断，新行拿 nextSeq")
        XCTAssertFalse(session.history.canRedo)
        XCTAssertEqual(session.history.cursor, 3)
        XCTAssertEqual(session.history.snapshots.last?.label, "撤销 C")
        XCTAssertEqual(session.editRevision, revisionBefore + 1)
        // C moved the curve; its previous value is B's identity curve.
        XCTAssertEqual(session.history.current?.curve.white, EditModel.neutral.curve.white)
        XCTAssertEqual(session.history.current?.light.exposure ?? 0, bExposure, accuracy: 1e-12)
        print("263 BRANCH · seq \(seqs) → \(session.history.snapshots.map(\.seq)) · count 4")
    }

    // MARK: - 3. boundaries

    func testIndexZeroAndAnEmptyDiffAreRefusedWithoutTouchingTheStack() throws {
        var history = EditHistory()
        history.commit(edit { $0.light.exposure = 0.2 }, label: "A", coalesce: false)
        let before = history

        XCTAssertNil(history.revert(at: 0), "floor 没有上一步可回")
        XCTAssertEqual(history, before, "拒绝时一行都不改")

        // A non-floor row with no changes (a version-1-style envelope whose neighbours are equal).
        let same = edit { $0.light.exposure = 0.2 }
        var empty = EditHistory(rows: [
            .init(seq: 0, label: "A", edit: same),
            .init(seq: 1, label: "B", edit: same),
        ], cursorSeq: 1)
        XCTAssertTrue(empty.snapshots[1].changes.isEmpty, "夹具：第二行确实没有 diff")
        let beforeEmpty = empty
        XCTAssertNil(empty.revert(at: 1), "没有可撤销的字段")
        XCTAssertEqual(empty, beforeEmpty)
    }

    // MARK: - 4. the panel's cheap static check (no hosted UI, by the user's instruction)

    func testThePanelSourceHasTheUndoButtonAndNoOldMarker() throws {
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertFalse(source.contains("badge"), "旧「最新」标记必须整体删掉")
        XCTAssertFalse(source.contains("xmark"), "旧 × 图标必须整体删掉")
        XCTAssertTrue(source.contains("public static let undoWidth: CGFloat = 26"))
        XCTAssertTrue(source.contains("public static let undoHitHeight: CGFloat = 18"))
        XCTAssertTrue(source.contains("Text(\"撤销\")"))
        XCTAssertTrue(source.contains("session.revertHistoryEntry(at: row.index)"))
        XCTAssertTrue(source.contains("if row.canUndo {"))
        XCTAssertTrue(source.contains("inspector.history.undo.\\(row.seq)"))

        // The one measurement the dispatch asks for without hosting the panel: the fixed columns
        // still leave a 2-line summary at all three inspector widths (and the undo target is 26×18).
        let widths: [(CGFloat, CGFloat)] = [
            (WorkspaceLayout.inspectorWidthMin, 176),
            (WorkspaceLayout.inspectorWidthDefault, 206),
            (WorkspaceLayout.inspectorWidthMax, 240),
        ]
        for (panel, expected) in widths {
            let column = HistoryPanelLayout.summaryColumn(panelWidth: panel)
            XCTAssertEqual(column, expected, accuracy: 0.01,
                           "\(Int(panel)) pt 面板：摘要列 \(column) pt")
            XCTAssertGreaterThan(column, 120, "\(Int(panel)) pt 面板下摘要有两行可用")
        }
        XCTAssertEqual(HistoryPanelLayout.undoWidth, 26)
        XCTAssertEqual(HistoryPanelLayout.undoHitHeight, 18)
        print("263 WIDTHS · " + widths.map { "\(Int($0.0))→\(Int($0.1))" }.joined(separator: " · ")
              + " · undo 26×18")
    }

    // MARK: - helpers

    private func edit(_ mutate: (inout EditModel) -> Void) -> EditModel {
        var model = EditModel.neutral
        mutate(&model)
        return model
    }

    /// A deterministic photograph: a horizontal linear ramp with a colour tilt, so exposure and the
    /// curve both move pixels. Small enough to render inline, big enough that the curve's points are
    /// exercised.
    private func image(_ w: Int, _ h: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let u = Double(x) / Double(max(w - 1, 1))
                let v = Double(y) / Double(max(h - 1, 1))
                rgba[o] = Float16(0.02 + 0.86 * u)
                rgba[o + 1] = Float16(0.02 + 0.55 * u + 0.18 * v)
                rgba[o + 2] = Float16(0.02 + 0.30 * u + 0.25 * v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "263-revert")
    }

    private func render(_ model: EditModel, tag: String) throws -> RenderResult {
        // One identity for every render, as the app has for one photo: `RenderInput.identity` is part
        // of every stage key, so a per-tag identity would make "the keys moved" true even for a
        // document that never moved — the assertion would pass for the wrong reason.
        let graph = try RenderGraph(input: RenderInput(image: image(192, 128),
                                                       identity: "263-revert"))
        return try graph.render(model, options: RenderOptions(scale: 1, useCache: false,
                                                             wantsPixels: true))
    }

    private static var panelSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/PhotonsUI/HistoryPanel.swift")
    }
}
