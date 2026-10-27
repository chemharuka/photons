import XCTest
import PhotonsCore

/// 派单 077 — the history panel's contracts: field-level diff, coalescing, tool sessions, deleting a
/// row, jumping.
///
/// `HistoryTests` is the D10 foundation (snapshot stack + cursor) and 077 must not break it; this file
/// is the new behaviour on top. Every test names the user's sentence it implements.
final class HistoryPanelTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func edit(_ mutate: (inout EditModel) -> Void) -> EditModel {
        var m = EditModel.neutral
        mutate(&m)
        return m
    }

    private func history(_ base: EditModel = .neutral, depth: Int = EditHistory.defaultMaxDepth) -> EditHistory {
        EditHistory(baseline: base, label: "Original", maxDepth: depth, now: t0)
    }

    /// `exposure` + `contrast` in one commit — a change of **two** classes, which 077 never merges.
    /// Used by the tests that need N distinct rows without depending on the merge rule.
    private func twoFields(_ i: Int) -> EditModel {
        edit { $0.light.exposure = Double(i); $0.light.contrast = -Double(i) }
    }

    // MARK: - ① 字段级 diff

    /// The resolution the panel needs: `light.exposure`, `curve.white[3].y`, `masks.m-1.feather` — a
    /// step says which *number* moved, not just "Light changed".
    func testChangedFieldsIsFieldLevel() {
        let fivePoints = [CurvePoint(0, 0), CurvePoint(0.4, 0.3), CurvePoint(0.9, 1.0),
                          CurvePoint(1.3, 1.6), CurvePoint(2, 2)]
        var movedPoint = fivePoints
        movedPoint[3].y = 1.8
        let base = edit {
            $0.curve.white = fivePoints
            $0.masks = [Mask(id: "m-1", feather: 0.1)]
        }
        let moved = edit {
            $0.curve.white = movedPoint
            $0.masks = [Mask(id: "m-1", feather: 0.35)]
        }

        let changes = EditHistory.changedFields(between: base, and: moved)
        XCTAssertEqual(changes.map(\.field.key), ["curve.white[3].y", "masks.m-1.feather"])
        XCTAssertEqual(changes[0].from, .number(1.6))
        XCTAssertEqual(changes[0].to, .number(1.8))
        XCTAssertEqual(changes[0].summary, "曲线 白[3].y +1.6 → +1.8")
        XCTAssertEqual(changes[1].summary, "蒙版 羽化 0.1 → 0.35")

        // A point *added* is a structural row, not a coordinate that happens to coincide.
        let grown = EditHistory.changedFields(between: edit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(2, 2)] },
                                              and: edit { $0.curve.white = fivePoints })
        XCTAssertEqual(grown.map(\.field.key), ["curve.white.count"])

        // The white balance's `nil` is a state, not a number.
        let wb = EditHistory.changedFields(between: .neutral,
                                           and: edit { $0.light.temperature = 5200 })
        XCTAssertEqual(wb.map(\.field.key), ["light.temperature"])
        XCTAssertEqual(wb[0].summary, "色温 原照 → +5200")

        // Tolerance is the cache's, so history and the renderer never disagree about "did it move".
        let jitter = EditHistory.changedFields(between: base,
                                               and: edit {
                                                   $0.curve.white = fivePoints
                                                   $0.masks = [Mask(id: "m-1", feather: 0.1 + 1e-9)]
                                               })
        XCTAssertEqual(jitter, [])

        // Every key has a name; the fallback is the key itself, never an empty string.
        for change in EditHistory.changedFields(between: .neutral,
                                                and: edit { $0.color.bands[2].hue = 12; $0.optics.caRed = 0.001 }) {
            XCTAssertFalse(change.field.displayName.isEmpty)
        }
        let band = EditHistory.changedFields(between: .neutral,
                                             and: edit { $0.color.bands[2].hue = 12 })
        XCTAssertEqual(band[0].field.displayName, "HSL[2] 色相")
    }

    // MARK: - ② 同参数连续拖动 = 一条

    /// 「多次拖动滑动条也只记录，开始下一步时，滑动条的值」 — five commits of one slider, one row,
    /// `0 → +1.2`, `seq` from the first.
    func testFiveDragsOfOneSliderAreOneRow() {
        var h = history()
        for v in [0.2, 0.4, 0.8, 1.0, 1.2] {
            h.commit(edit { $0.light.exposure = v }, label: "曝光", now: t0)
        }

        XCTAssertEqual(h.count, 2, "基线 + 一条合并后的拖动")
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1], "合并保留串起点的 seq")
        XCTAssertEqual(h.cursor, 1)
        XCTAssertEqual(h.current?.light.exposure ?? 0, 1.2, accuracy: 1e-12, "文档是串终点")
        XCTAssertEqual(h.changedFields(at: 1).map(\.field.key), ["light.exposure"])
        XCTAssertEqual(h.changedFields(at: 1).first?.from, .number(0))
        XCTAssertEqual(h.changedFields(at: 1).first?.to, .number(1.2))
        XCTAssertEqual(h.nextSeq, 2, "nextSeq 不因为合并而回退")
        XCTAssertEqual(h.rows[1].summary, "曝光 0 → +1.2")
        print("MERGE 5 drags → seq \(h.snapshots.map(\.seq)) · \(h.rows[1].summary)")
    }

    /// 曝光 / 对比 / 曝光 交替 → **3 条**：中间夹了别的类就断开。
    func testAlternatingParametersAreThreeRows() {
        var h = history()
        h.commit(edit { $0.light.exposure = 0.5 }, label: "曝光", now: t0)
        h.commit(edit { $0.light.exposure = 0.5; $0.light.contrast = 20 }, label: "对比", now: t0)
        h.commit(edit { $0.light.exposure = 0.9; $0.light.contrast = 20 }, label: "曝光", now: t0)

        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(h.snapshots.count, 4)
        XCTAssertEqual(h.changedFields(at: 3).map(\.field.key), ["light.exposure"],
                       "第二根曝光是它自己的那一行，不是并回第一行")
        XCTAssertEqual(h.changedFields(at: 3).first?.from, .number(0.5))
        XCTAssertEqual(h.changedFields(at: 3).first?.to, .number(0.9))
        print("ALTERNATE exposure/contrast/exposure → seq \(h.snapshots.map(\.seq))")
    }

    /// Dragging one curve **point** moves x and y at once and is still one gesture → one row.
    func testCurvePointDragIsOneRow() {
        var h = history(edit {
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(2, 2)]
        })
        for y in [0.55, 0.62, 0.7] {
            h.commit(edit {
                $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, y), CurvePoint(2, 2)]
            }, label: "曲线", now: t0)
        }
        XCTAssertEqual(h.count, 2)
        let keys: Set<String> = Set(h.changedFields(at: 1).map { $0.field.key })
        XCTAssertEqual(keys, ["curve.white[1].y"])
        XCTAssertEqual(h.changedFields(at: 1).first?.to, FieldValue.number(0.7))
    }

    /// 拖过去又拖回来：那一行整个消失，并且不产生新的 seq。
    func testDraggingBackToTheStartLeavesNoRow() {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "曝光", now: t0)
        XCTAssertEqual(h.nextSeq, 2)
        XCTAssertNil(h.commit(edit { $0.light.exposure = 0 }, label: "拖回", now: t0))

        XCTAssertEqual(h.count, 1, "没有内容的一行不该留在时间线上")
        XCTAssertEqual(h.cursor, 0)
        XCTAssertEqual(h.current, EditModel.neutral)
        XCTAssertEqual(h.nextSeq, 2, "seq 不回收")
    }

    /// 合并只在**末尾**发生：撤销之后的新提交是一行新的，不是并回栈顶。
    func testACommitAfterUndoIsNeverMerged() {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "曝光", now: t0)
        h.commit(edit { $0.light.contrast = 20 }, label: "对比", now: t0)
        h.undo()
        XCTAssertEqual(h.current?.light.exposure ?? 0, 1, accuracy: 1e-12)

        XCTAssertNotNil(h.commit(edit { $0.light.exposure = 1.4 }, label: "曝光", now: t0))
        XCTAssertEqual(h.count, 3, "0 / 曝光 / 曝光(新) —— 中间的 redo 尾被截掉")
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 3], "被截掉的 2 号不复用")
    }

    // MARK: - ③ 工具会话一条

    /// 裁切：中途 20 次几何变更 → `snapshots.count` **+1**，而且那一条是"进入前 → 应用后"。
    func testTwentyChangesInsideOneCropSessionAreOneSnapshot() {
        var h = history()
        let start = h.count
        h.beginSession("裁切")
        XCTAssertTrue(h.isSessionActive)

        for i in 1...20 {
            // Every handle move reaches `commit` — the session is what refuses them, not the UI.
            let rect = NormalizedRect(x: Double(i) / 100, y: Double(i) / 200,
                                      width: 0.5, height: 0.4)
            XCTAssertNil(h.commit(edit { $0.geometry.crop = rect }, label: "裁切", now: t0),
                         "会话里的提交一条都不落")
        }
        let final = edit { $0.geometry.crop = NormalizedRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4) }
        let snap = h.endSession(final, now: t0)

        XCTAssertNotNil(snap)
        XCTAssertEqual(h.count, start + 1, "一次会话一条")
        XCTAssertEqual(h.snapshots.last?.label, "裁切")
        XCTAssertEqual(h.current, final)
        let keys = Set(h.changedFields(at: h.count - 1).map(\.field.key))
        XCTAssertEqual(keys, ["geometry.crop.x", "geometry.crop.y",
                             "geometry.crop.width", "geometry.crop.height"],
                       "只有进入前 → 应用后的差：中间那 20 个点位一个都不在")
        XCTAssertFalse(h.isSessionActive)
        print("CROP SESSION 20 changes → rows \(start) → \(h.count) · \(h.rows.last!.summary)")
    }

    /// 取消 → **零条**，而且此前存在的 redo 尾原样保留（什么都没发生）。
    func testCancelledSessionRecordsNothing() {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "曝光", now: t0)
        h.commit(edit { $0.light.contrast = 20 }, label: "对比", now: t0)
        h.undo()
        XCTAssertTrue(h.canRedo)
        let before = h.snapshots

        h.beginSession("裁切")
        for i in 1...5 {
            h.commit(edit { $0.geometry.rotationDegrees = Double(i) }, label: "旋转", now: t0)
        }
        h.cancelSession()

        XCTAssertEqual(h.snapshots, before, "取消 = 栈逐字节不变")
        XCTAssertTrue(h.canRedo, "取消不该截掉 redo 尾")
        XCTAssertFalse(h.isSessionActive)
    }

    /// 会话里什么都没动（进了裁切、按应用、没拖）→ 零条。
    func testSessionThatChangedNothingRecordsNothing() {
        var h = history()
        let before = h.snapshots
        h.beginSession("裁切")
        XCTAssertNil(h.endSession(EditModel.neutral, now: t0))
        XCTAssertEqual(h.snapshots, before)
        XCTAssertEqual(h.nextSeq, 1)
    }

    /// 两次裁切会话 = 两条，不因为"同 class 连续"而并成一条：会话自己声明了边界。
    func testTwoCropSessionsAreTwoRows() {
        var h = history()
        h.beginSession("裁切")
        h.endSession(edit { $0.geometry.crop = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5) }, now: t0)
        h.beginSession("裁切")
        h.endSession(edit { $0.geometry.crop = NormalizedRect(x: 0, y: 0, width: 0.4, height: 0.4) }, now: t0)
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 2])
    }

    // MARK: - ④ 删除一行

    /// The 8-step acceptance timeline: 曝光 ×3 (one drag) / 对比 / 曝光 / 曲线 / 蒙版羽化 / 裁切会话.
    ///
    /// Returns the history plus the indexes the other delete tests address rows by.
    private func eightSteps() -> (history: EditHistory, contrastIndex: Int, coveredExposureIndex: Int) {
        var h = history()
        // 1–3: one continuous drag of 曝光.
        for v in [0.5, 0.9, 1.2] { h.commit(edit { $0.light.exposure = v }, label: "曝光", now: t0) }
        // 4: 对比.
        h.commit(edit { $0.light.exposure = 1.2; $0.light.contrast = 20 }, label: "对比", now: t0)
        // 5: 曝光 again — a new row, because 对比 broke the run.
        h.commit(edit { $0.light.exposure = 1.8; $0.light.contrast = 20 }, label: "曝光", now: t0)
        // 6: a curve point list of three (structural: 点数 2 → 3).
        h.commit(edit {
            $0.light.exposure = 1.8; $0.light.contrast = 20
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.6, 0.75), CurvePoint(2, 2)]
        }, label: "曲线", now: t0)
        // 7: 蒙版 羽化.
        h.commit(edit {
            $0.light.exposure = 1.8; $0.light.contrast = 20
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.6, 0.75), CurvePoint(2, 2)]
            $0.masks = [Mask(id: "m-1", feather: 0.35)]
        }, label: "蒙版", now: t0)
        // 8: the crop session — 20 intermediate rects, one row.
        h.beginSession("裁切", label: "裁切")
        for i in 1...20 {
            h.commit(edit {
                $0.light.exposure = 1.8; $0.light.contrast = 20
                $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.6, 0.75), CurvePoint(2, 2)]
                $0.masks = [Mask(id: "m-1", feather: 0.35)]
                $0.geometry.crop = NormalizedRect(x: Double(i) / 100, y: 0, width: 0.5, height: 0.5)
            }, now: t0)
        }
        h.endSession(edit {
            $0.light.exposure = 1.8; $0.light.contrast = 20
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.6, 0.75), CurvePoint(2, 2)]
            $0.masks = [Mask(id: "m-1", feather: 0.35)]
            $0.geometry.crop = NormalizedRect(x: 0.1, y: 0, width: 0.5, height: 0.5)
        }, now: t0)
        return (h, 2, 1)
    }

    /// The table the ticket asks for: `seq / label / changedFields / cursor` and the `deletable` column.
    func testEightStepTimelineTable() {
        let (h, _, _) = eightSteps()
        XCTAssertEqual(h.count, 7, "基线 + 曝光 + 对比 + 曝光 + 曲线 + 蒙版 + 裁切")
        XCTAssertEqual(h.cursor, 6)

        var lines: [String] = []
        for row in h.rows {
            lines.append("seq \(row.seq) · \(row.label) · [\(row.fields.joined(separator: ", "))]"
                         + " · \(row.summary) · 最新=\(row.isNewestOfClass) 可删=\(row.canDelete)")
        }
        print("TIMELINE\n" + lines.joined(separator: "\n"))

        XCTAssertEqual(h.rows.map(\.seq), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(h.rows.map(\.label),
                       ["Original", "曝光", "对比", "曝光", "曲线", "蒙版", "裁切"])
        XCTAssertEqual(h.rows.map(\.isNewestOfClass),
                       [false, false, true, true, true, true, true],
                       "只有「对比」以及它之后的每一类最新一条可删；被 1.8 覆盖的第一次曝光不行")
        XCTAssertEqual(h.rows.map(\.canDelete), h.rows.map(\.isNewestOfClass),
                       "标识与可删是同一个谓词")

        // Which seqs the table names in full — the acceptance's 「给合并后的快照表」.
        XCTAssertEqual(h.changedFields(at: 1).map(\.field.key), ["light.exposure"])
        XCTAssertEqual(h.changedFields(at: 1).first?.to, .number(1.2))
        XCTAssertEqual(h.changedFields(at: 2).map(\.field.key), ["light.contrast"])
        XCTAssertEqual(h.changedFields(at: 3).map(\.field.key), ["light.exposure"])
        XCTAssertEqual(h.changedFields(at: 4).map(\.field.key), ["curve.white.count"])
        XCTAssertEqual(h.changedFields(at: 5).map(\.field.key),
                       ["masks.m-1.added", "masks.m-1.feather", "masks.order"])
        XCTAssertEqual(Set(h.changedFields(at: 6).map(\.field.key)),
                       ["geometry.crop.x", "geometry.crop.width", "geometry.crop.height"],
                       "裁切会话只有进入前 → 应用后的差")
    }

    /// 删中间一条（对比）：列表少一行，其余行**逐字不变**，`nextSeq` 不变，`cursor` 正确。
    func testDeletingAMiddleRowLeavesEveryOtherRowByteIdentical() {
        var (h, contrastIndex, _) = eightSteps()
        let before = h.snapshots
        let nextSeqBefore = h.nextSeq
        let cursorSeqBefore = h.currentSeq
        let removed = before[contrastIndex]

        XCTAssertTrue(h.deletable(at: contrastIndex))
        XCTAssertTrue(h.delete(at: contrastIndex))

        XCTAssertEqual(h.count, before.count - 1, "少一行")
        XCTAssertEqual(h.snapshots, before.filter { $0.seq != removed.seq },
                       "其余行 seq / label / edit / changes / createdAt 全等")
        XCTAssertEqual(h.nextSeq, nextSeqBefore, "nextSeq 不变")
        XCTAssertEqual(h.currentSeq, cursorSeqBefore, "cursor 仍指着同一条")
        XCTAssertEqual(h.current, before.last?.edit, "屏幕上那张图不变")

        // …and a new commit continues from the untouched counter.
        h.commit(edit { $0.effects.grain = 5 }, label: "颗粒", now: t0)
        XCTAssertEqual(h.snapshots.last?.seq, nextSeqBefore)
    }

    /// 删已被覆盖的「曝光 +0.5」→ false，列表不变。
    func testDeletingACoveredRowIsRefused() {
        var (h, _, covered) = eightSteps()
        let before = h.snapshots
        XCTAssertFalse(h.isNewestOfClass(at: covered))
        XCTAssertFalse(h.delete(at: covered))
        XCTAssertEqual(h.snapshots, before, "拒绝时一个字都不动")

        // The baseline is never deletable either — it is the floor of undo.
        XCTAssertFalse(h.deletable(at: 0))
        XCTAssertFalse(h.delete(at: 0))
    }

    /// 删掉站着的那一行：cursor 落到时间上的前一行，文档跟着走（一次重渲）。
    func testDeletingTheCurrentRowMovesTheCursorToItsPredecessor() {
        var (h, contrastIndex, _) = eightSteps()
        XCTAssertEqual(h.cursor, 6)
        // Jump to the contrast row, then delete it.
        XCTAssertNotNil(h.jump(to: h.snapshots[contrastIndex].seq))
        XCTAssertEqual(h.cursor, contrastIndex)
        let predecessor = h.snapshots[contrastIndex - 1].edit

        XCTAssertTrue(h.delete(at: contrastIndex))
        XCTAssertEqual(h.cursor, contrastIndex - 1)
        XCTAssertEqual(h.current, predecessor)
    }

    /// 删 redo 尾里的一行：cursor 不动。
    func testDeletingARowAheadOfTheCursorLeavesTheCursorAlone() {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "曝光", now: t0)
        h.commit(edit { $0.light.contrast = 20 }, label: "对比", now: t0)
        h.commit(edit { $0.color.saturation = 10 }, label: "饱和", now: t0)
        h.jump(to: 1)                                   // the exposure row
        XCTAssertEqual(h.cursor, 1)

        XCTAssertTrue(h.delete(at: 3))                  // 饱和, ahead of the cursor
        XCTAssertEqual(h.cursor, 1)
        XCTAssertEqual(h.current?.light.exposure ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(h.count, 3)
    }

    // MARK: - ⑤ 跳转

    /// 跳转 = 移 cursor + 一次重渲 + **不新增快照**；再撤销回到原处；之后的编辑截掉老尾。
    func testJumpMovesTheCursorWithoutANewSnapshotAndTheNextEditTruncates() {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "曝光", now: t0)
        h.commit(edit { $0.light.contrast = 20 }, label: "对比", now: t0)
        h.commit(edit { $0.color.saturation = 10 }, label: "饱和", now: t0)
        let seqs = h.snapshots.map(\.seq)
        let tipEdit = h.current

        XCTAssertEqual(h.jump(to: seqs[1]), h.snapshots[1].edit, "文档 == 该行的 edit")
        XCTAssertEqual(h.count, 4, "跳转不新增快照")
        XCTAssertEqual(h.snapshots.map(\.seq), seqs, "跳转也不删行")
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.redo(), h.snapshots[2].edit, "再撤销/恢复回末行")
        XCTAssertEqual(h.redo(), tipEdit)
        XCTAssertEqual(h.cursor, 3)

        // 跳回去再编辑：老尾没了，seq 表说明新行拿的是下一个空号。
        h.jump(to: seqs[1])
        h.commit(edit { $0.light.exposure = 1; $0.effects.vignetteAmount = -20 },
                 label: "暗角", now: t0)
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 4])
        XCTAssertFalse(h.canRedo)
        print("JUMP seqs \(seqs) → after jump-back + edit: \(h.snapshots.map(\.seq))")
    }

    /// The same claim at the pixel level: the state a jump lands on renders to the same bytes as the
    /// first time it was on screen. Skipped when the RAW fixture is not on this machine.
    func testJumpedToStateRendersTheSamePixels() throws {
        let url = try fixtureURL()
        let image = try RAWDecoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: 0.125))
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "077-jump"))
        let opts = RenderOptions(scale: 0.25, wantsPixels: true)

        var h = history()
        let a = edit { $0.light.exposure = 0.6 }
        let b = edit { $0.light.exposure = 0.6; $0.light.contrast = 25 }
        let c = edit { $0.light.exposure = 0.6; $0.light.contrast = 25; $0.color.saturation = 12 }
        h.commit(a, label: "曝光", now: t0)
        h.commit(b, label: "对比", now: t0)
        h.commit(c, label: "饱和", now: t0)

        // Render every committed state once (cold-ish) — these are the reference pixels.
        let pixelsA = try XCTUnwrap(graph.render(a, options: opts).display).sha256()
        let pixelsB = try XCTUnwrap(graph.render(b, options: opts).display).sha256()
        let pixelsC = try XCTUnwrap(graph.render(c, options: opts).display).sha256()
        XCTAssertNotEqual(pixelsA, pixelsB)
        XCTAssertNotEqual(pixelsB, pixelsC)

        // A jump shows the state it lands on: same document, same pixels, no new snapshot.
        let atTwo = try XCTUnwrap(h.jump(to: 2))
        XCTAssertEqual(atTwo, b)
        XCTAssertEqual(try XCTUnwrap(graph.render(atTwo, options: opts).display).sha256(), pixelsB,
                       "跳到第 2 行 == 当时那一行渲出来的像素")
        XCTAssertEqual(h.count, 4, "跳转不新增快照")

        let atOne = try XCTUnwrap(h.jump(to: 1))
        XCTAssertEqual(try XCTUnwrap(graph.render(atOne, options: opts).display).sha256(), pixelsA)
        XCTAssertNotNil(h.jumpToTip())
        XCTAssertEqual(try XCTUnwrap(graph.render(h.current!, options: opts).display).sha256(), pixelsC)
        print("JUMP pixels · seq1 \(pixelsA.prefix(12))… · seq2 \(pixelsB.prefix(12))…"
              + " · seq3 \(pixelsC.prefix(12))…")
    }

    // MARK: - ⑥ rows / envelope

    /// The panel's rows come from the model, and a version-1 envelope (no `changes`) opens readable.
    func testVersionOneEnvelopeIsBackfilledOnLoad() throws {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "曝光", now: t0)
        h.commit(edit { $0.light.exposure = 1; $0.light.contrast = 20 }, label: "对比", now: t0)

        // Strip `changes` and the version, i.e. exactly what a pre-077 envelope looks like.
        let data = try JSONEncoder().encode(h)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["schemaVersion"] = 1
        obj["snapshots"] = (obj["snapshots"] as? [[String: Any]])?.map { snap -> [String: Any] in
            var copy = snap
            copy.removeValue(forKey: "changes")
            return copy
        }
        let old = try JSONDecoder().decode(
            EditHistory.self, from: try JSONSerialization.data(withJSONObject: obj))

        XCTAssertEqual(old.count, 3)
        XCTAssertEqual(old.rows.map(\.summary), ["原始状态", "曝光 0 → +1", "对比 0 → +20"])
        XCTAssertEqual(old.rows.map(\.canDelete), [false, true, true],
                       "补算出来的 diff 也能回答可删性")
        XCTAssertEqual(old.cursor, 2)
    }

    /// The envelope round-trips the diff too (the panel must read the same text after a reopen).
    func testEnvelopeRoundTripsTheFieldDiff() throws {
        var h = history()
        h.commit(edit { $0.masks = [Mask(id: "m-1", feather: 0.2)] }, label: "蒙版", now: t0)
        let back = try JSONDecoder().decode(EditHistory.self, from: try JSONEncoder().encode(h))
        XCTAssertEqual(back, h)
        XCTAssertEqual(back.rows, h.rows)
        XCTAssertEqual(back.snapshots.last?.changes, h.snapshots.last?.changes)
    }

    /// A 1000-row stack: `rows` is a straight pass, and every row's flags are the model's.
    func testThousandRowStackKeepsRowsCheapAndCorrect() {
        var h = history(depth: 2000)
        for i in 1...1000 { h.commit(twoFields(i), label: "e\(i)", now: t0) }
        XCTAssertEqual(h.count, 1001)
        let start = Date()
        let rows = h.rows
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(rows.count, 1001)
        XCTAssertEqual(rows.filter(\.canDelete).count, 1,
                       "两类都被人碰过，所以只有最后一行是各类最新（可删）")
        XCTAssertLessThan(elapsed, 0.5, "1000 行的行表必须是线性的一趟（实测 \(elapsed)s）")
        XCTAssertEqual(rows.last?.isCurrent, true)
    }

    // MARK: - fixtures

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }
}
