import XCTest
import PhotonsCore

/// M3 unit tests: the parameter snapshot stack (D10).
///
/// Pure model — no renderer, no fixtures, no RAW, so these run everywhere and are the contract the
/// history panel in the UI will be written against.
final class HistoryTests: XCTestCase {

    // MARK: helpers

    /// A neutral document with one mutation applied — the shape of one edit action.
    private func edit(_ mutate: (inout EditModel) -> Void) -> EditModel {
        var m = EditModel.neutral
        mutate(&m)
        return m
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func history(_ base: EditModel = .neutral, depth: Int = EditHistory.defaultMaxDepth) -> EditHistory {
        EditHistory(baseline: base, label: "Original", maxDepth: depth, now: t0)
    }

    // MARK: ① undo / redo walk

    func testCommitThenUndoRedoWalksTheStackInOrder() {
        var h = history()
        let a = edit { $0.light.exposure = 1 }
        let b = edit { $0.light.contrast = 20 }
        let c = edit { $0.color.saturation = 30 }

        h.commit(a, label: "Exposure")
        h.commit(b, label: "Contrast")
        h.commit(c, label: "Saturation")

        XCTAssertEqual(h.count, 4)
        XCTAssertEqual(h.cursor, 3)
        XCTAssertEqual(h.current, c)
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(h.snapshots.map(\.label), ["Original", "Exposure", "Contrast", "Saturation"])
        XCTAssertEqual(h.undoLabel, "Saturation")
        XCTAssertNil(h.redoLabel)

        // undo walks backwards one committed state at a time
        XCTAssertEqual(h.undo(), b)
        XCTAssertEqual(h.cursor, 2)
        XCTAssertEqual(h.current, b)
        XCTAssertEqual(h.undoLabel, "Contrast")
        XCTAssertEqual(h.redoLabel, "Saturation")

        XCTAssertEqual(h.undo(), a)
        XCTAssertEqual(h.undo(), EditModel.neutral)
        XCTAssertEqual(h.cursor, 0)
        XCTAssertFalse(h.canUndo)
        XCTAssertTrue(h.canRedo)
        XCTAssertNil(h.undo())                       // floor: the baseline is not undoable
        XCTAssertEqual(h.current, EditModel.neutral)

        // redo walks forward over exactly the same states
        XCTAssertEqual(h.redo(), a)
        XCTAssertEqual(h.redo(), b)
        XCTAssertEqual(h.redo(), c)
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.redo())                       // tip
        XCTAssertEqual(h.current, c)
    }

    // MARK: ② a commit after undo truncates the redo branch

    func testCommitAfterUndoTruncatesRedoBranch() {
        var h = history()
        let a = edit { $0.light.exposure = 1 }
        let b = edit { $0.light.contrast = 20 }
        let c = edit { $0.color.saturation = 30 }
        h.commit(a, label: "Exposure")
        h.commit(b, label: "Contrast")
        h.commit(c, label: "Saturation")
        let seqOfC = h.snapshots.last!.seq

        XCTAssertEqual(h.undo(), b)
        XCTAssertEqual(h.undo(), a)
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.count, 4)                   // undo alone never drops anything

        let d = edit { $0.effects.vignetteAmount = -30 }
        let committed = h.commit(d, label: "Vignette")

        XCTAssertNotNil(committed)
        XCTAssertEqual(h.count, 3)                   // Original, Exposure, Vignette
        XCTAssertEqual(h.snapshots.map(\.label), ["Original", "Exposure", "Vignette"])
        XCTAssertFalse(h.canRedo)                    // the branch is gone, not merely unreachable
        XCTAssertEqual(h.current, d)
        XCTAssertNil(h.jump(to: seqOfC))
        // seqs are not renumbered by the truncation; the new snapshot takes the next free seq
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 4])
        XCTAssertEqual(h.nextSeq, 5)
    }

    // MARK: ③ depth cap

    func testDepthCapDropsOldestAndKeepsCursorInBounds() {
        var h = history(depth: 3)
        // 077（2026-10-27）:**每次提交改两个字段**。这条用例的主体是保留深度与游标，
        // 而它原先用 10 次连续 `light.exposure` 驱动 —— 按 077 的合并契约那已经是**一行**
        // （同 class 连续拖动 = 一次操作）。改参数而不是改断言：cap / 淘汰 / 游标 / seq 全部原样。
        // 合并本身由 `HistoryPanelTests.testFiveDragsOfOneSliderAreOneRow` 正面钉住。
        for i in 1...10 {
            h.commit(edit { $0.light.exposure = Double(i); $0.light.contrast = -Double(i) },
                     label: "e\(i)", now: t0)
            XCTAssertLessThan(h.cursor, h.count)
            XCTAssertGreaterThanOrEqual(h.cursor, 0)
        }

        XCTAssertEqual(h.count, 3)                   // the cap is the retention window
        XCTAssertEqual(h.snapshots.map(\.label), ["e8", "e9", "e10"])
        XCTAssertEqual(h.cursor, 2)
        XCTAssertEqual(h.current?.light.exposure, 10)
        // oldest Seq went away, the survivors keep their original numbering
        XCTAssertEqual(h.snapshots.map(\.seq), [8, 9, 10])
        XCTAssertEqual(h.nextSeq, 11)

        // the evicted tail is unreachable: undo stops at the oldest survivor with the cursor at 0
        XCTAssertEqual(h.undo()?.light.exposure, 9)
        XCTAssertEqual(h.undo()?.light.exposure, 8)
        XCTAssertNil(h.undo())
        XCTAssertEqual(h.cursor, 0)
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.current?.light.exposure, 8)

        // committing off the oldest survivor truncates the rest of the window (it is the redo
        // branch), so the stack shrinks rather than silently keeping unreachable states
        h.commit(edit { $0.light.exposure = 42 }, label: "e42", now: t0)
        XCTAssertEqual(h.snapshots.map(\.label), ["e8", "e42"])
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h.cursor, 1)
        XCTAssertFalse(h.canRedo)
        XCTAssertLessThan(h.cursor, h.count)
    }

    func testDepthOneKeepsOnlyTheCurrentState() {
        var h = history(depth: 1)
        h.commit(edit { $0.light.exposure = 1 }, label: "one", now: t0)
        h.commit(edit { $0.light.exposure = 2 }, label: "two", now: t0)
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h.current?.light.exposure, 2)
        XCTAssertEqual(h.cursor, 0)
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
    }

    func testShrinkingDepthKeepsTheCursorOnTheSameSnapshot() {
        var h = history()
        // 077（2026-10-27）: 同前一条 —— 连续同参数提交已是一行，所以每次提交改两个字段。
        for i in 1...5 {
            h.commit(edit { $0.light.exposure = Double(i); $0.light.contrast = -Double(i) },
                     label: "e\(i)", now: t0)
        }
        XCTAssertEqual(h.cursor, 5)

        h.setMaxDepth(3)
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.cursor, 2)
        XCTAssertEqual(h.current?.light.exposure, 5)  // still the state that was on screen
        XCTAssertEqual(h.snapshots.map(\.seq), [3, 4, 5])

        h.setMaxDepth(0)                              // clamped, never a stack that forgets itself
        XCTAssertEqual(h.maxDepth, 1)
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h.cursor, 0)
        XCTAssertEqual(h.current?.light.exposure, 5)
    }

    // MARK: ④ no-op commits

    func testCommittingTheSameEditIsANoOp() {
        var h = history()
        let a = edit { $0.light.exposure = 1 }
        XCTAssertNotNil(h.commit(a, label: "Exposure", now: t0))
        let before = h.snapshots

        XCTAssertNil(h.commit(a, label: "Exposure again", now: t0))
        XCTAssertEqual(h.snapshots, before)                 // not even the label is clobbered
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h.snapshots.last?.label, "Exposure")

        // a copy that is merely a re-serialisation is also a no-op
        let json = try! JSONEncoder().encode(a)
        let decoded = try! JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertNil(h.commit(decoded, label: "round-trip", now: t0))
        XCTAssertEqual(h.count, 2)

        // and a no-op must not damage a redo branch
        let b = edit { $0.light.contrast = 20 }
        h.commit(b, label: "Contrast", now: t0)
        XCTAssertEqual(h.undo(), a)
        XCTAssertTrue(h.canRedo)
        XCTAssertNil(h.commit(a, label: "same state", now: t0))
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.count, 3)
    }

    func testCommitOnEmptyHistoryAndDerivedLabels() {
        var h = EditHistory(maxDepth: 4)
        XCTAssertTrue(h.isEmpty)
        XCTAssertNil(h.current)
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.undo())
        XCTAssertNil(h.redo())

        let snap = h.commit(edit { $0.light.exposure = 1 }, now: t0)
        XCTAssertEqual(snap?.seq, 0)
        XCTAssertEqual(snap?.label, "Light")                 // label derived from the dirty group
        XCTAssertEqual(h.count, 1)
        XCTAssertFalse(h.canUndo)

        // derived against the state on screen, not against the document: exposure is already 1,
        // so only Color is dirty here
        h.commit(edit { $0.light.exposure = 1; $0.color.saturation = 5 }, label: "  ", now: t0)
        XCTAssertEqual(h.snapshots.last?.label, "Color")
        h.commit(edit { $0.light.exposure = 2; $0.color.saturation = 9 }, label: "", now: t0)
        XCTAssertEqual(h.snapshots.last?.label, "Light + Color")
    }

    // MARK: ⑤ group-level dirty marking

    func testDirtyGroupsReportOnlyTheGroupThatChanged() {
        let base = EditModel.neutral
        func dirty(_ mutate: (inout EditModel) -> Void) -> Set<RenderGroup> {
            EditHistory.dirtyGroups(from: base, to: edit(mutate))
        }

        XCTAssertEqual(dirty { _ in }, [])
        XCTAssertEqual(dirty { $0.light.exposure = 0.5 }, [.light])
        XCTAssertEqual(dirty { $0.light.temperature = 5200 }, [.light])
        XCTAssertEqual(dirty { $0.light.highlightRecovery = 0.4 }, [.light])
        XCTAssertEqual(dirty { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.6), CurvePoint(u: 1, v: 1)] },
                       [.curve])
        XCTAssertEqual(dirty { $0.curve.blue = [CurvePoint(u: 0, v: 0.1), CurvePoint(u: 1, v: 1)] }, [.curve])
        XCTAssertEqual(dirty { $0.color.saturation = 30 }, [.color])
        XCTAssertEqual(dirty { $0.color.bands[3].hue = 12 }, [.color])
        XCTAssertEqual(dirty { $0.detail.sharpening = 40 }, [.detail])
        XCTAssertEqual(dirty { $0.detail.lensCorrections = true }, [.detail])
        XCTAssertEqual(dirty { $0.effects.vignetteAmount = -30 }, [.effects])
        XCTAssertEqual(dirty { $0.geometry.rotationDegrees = 1.5 }, [.geometry])
        XCTAssertEqual(dirty { $0.geometry.crop.width = 0.5 }, [.geometry])
        XCTAssertEqual(dirty { $0.masks = [Mask(id: "m-1")] }, [.masks])

        // multi-group edits report exactly the groups touched
        XCTAssertEqual(dirty { $0.light.contrast = 10; $0.color.vibrance = 20 }, [.light, .color])
        XCTAssertEqual(dirty { $0.geometry.flipHorizontal = true; $0.effects.vignetteAmount = 5 },
                       [.geometry, .effects])

        // symmetric and order-independent
        let changed = edit { $0.curve.red = [CurvePoint(u: 0, v: 0.2), CurvePoint(u: 1, v: 1)] }
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: changed),
                       EditHistory.dirtyGroups(from: changed, to: base))

        // the instance spelling answers the same question
        XCTAssertEqual(EditHistory(baseline: base).dirtyGroups(from: base, to: changed), [.curve])
    }

    func testVersionBumpDirtiesEveryGroup() {
        let base = EditModel.neutral
        var bumped = base
        bumped.processVersion = EditModel.currentProcessVersion + 1
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: bumped), Set(RenderGroup.allCases))
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: bumped),
                       Set(RenderGroup.allCases), "a version bump changes meaning, not values")
    }

    func testGroupToStageMapping() {
        XCTAssertEqual(EditHistory.dirtyStages(for: [.light]), [.sceneLinear, .toneMap])
        XCTAssertEqual(EditHistory.dirtyStages(for: [.geometry]), [.geometry])
        XCTAssertEqual(EditHistory.dirtyStages(for: [.effects]), [.vignette])
        XCTAssertEqual(EditHistory.dirtyStages(for: [.detail]), [])   // stored, not rendered
        // 056: the masks group feeds S3.5 as well — a mask's hue/saturation moved there.
        XCTAssertEqual(EditHistory.dirtyStages(for: [.masks]), [.maskAtlas, .localApply, .localColor])
        XCTAssertEqual(EditHistory.dirtyStages(for: [.light, .masks]),
                       [.sceneLinear, .toneMap, .maskAtlas, .localApply, .localColor])
        XCTAssertFalse(RenderGroup.detail.affectsRender)
        XCTAssertTrue(RenderGroup.curve.affectsRender)
        XCTAssertTrue(RenderGroup.masks.affectsRender)
    }

    // MARK: ⑥ float tolerance

    func testFloatToleranceDecidesDirtiness() {
        let base = EditModel.neutral

        // 1e-9 is double noise from a JSON round-trip, not an edit
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: edit { $0.light.exposure = 1e-9 }), [])
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: edit { $0.color.vibrance = -1e-9 }), [])
        // White balance is measured between two *pinned* values, because as shot (`nil`) is a state
        // rather than a number (派单 006): an explicit value must never be "the same as" `nil`, or a
        // document that stops following the file would produce no history entry at all.
        let wbBase = edit { $0.light.temperature = 5200; $0.light.tint = 8 }
        XCTAssertEqual(EditHistory.dirtyGroups(from: wbBase,
                                               to: edit { $0.light.temperature = 5200 + 1e-9; $0.light.tint = 8 }), [])
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: wbBase), [.light],
                       "as shot → explicit is a different document, however small the numbers are")
        XCTAssertEqual(EditHistory.dirtyGroups(from: wbBase, to: base), [.light])
        let curveBase = edit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5), CurvePoint(u: 1, v: 1)] }
        XCTAssertEqual(EditHistory.dirtyGroups(
            from: curveBase,
            to: edit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5 + 1e-9), CurvePoint(u: 1, v: 1)] }
        ), [])

        // 1e-3 is a real change (one slider quantum at a hundredth of a stop)
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: edit { $0.light.exposure = 1e-3 }), [.light])
        XCTAssertEqual(EditHistory.dirtyGroups(from: wbBase,
                                               to: edit { $0.light.temperature = 5200 + 1e-3; $0.light.tint = 8 }), [.light])
        XCTAssertEqual(EditHistory.dirtyGroups(
            from: curveBase,
            to: edit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5 + 1e-3), CurvePoint(u: 1, v: 1)] }
        ), [.curve])

        // exactly at the tolerance is still "the same"; just past it is not
        let tol = EditHistory.dirtyTolerance
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: edit { $0.light.exposure = tol }), [])
        XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: edit { $0.light.exposure = tol * 2 }), [.light])

        // The curve uses that **same** window, and not "any move at all". This is the assertion that
        // separates the two answers for 069's `==` on the coordinate: it made a sub-tolerance point
        // move dirty (the jitter case above), and it would make the two lines below fail in the
        // opposite direction. Measured in card units, where `dirtyTolerance` lives — `CurvePoint(_:_:)`
        // is the `0…2` card pair, `CurvePoint(u:v:)` is the engine's `0…1` axis and doubles it.
        // The nudge starts from 0 on purpose: `1e-6` and `2e-6` are exact doubles, `2 + 1e-6` is not,
        // and a boundary test that is one ulp off the tolerance tests the wrong thing.
        XCTAssertEqual(EditHistory.dirtyGroups(
            from: base,
            to: edit { $0.curve.white = [CurvePoint(0, tol), CurvePoint(2, 2)] }
        ), [], "exactly at the tolerance the curve is the same document")
        XCTAssertEqual(EditHistory.dirtyGroups(
            from: base,
            to: edit { $0.curve.white = [CurvePoint(0, tol * 2), CurvePoint(2, 2)] }
        ), [.curve], "past the tolerance it is an edit")

        // and a jitter does not grow the stack
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "Exposure", now: t0)
        XCTAssertNil(h.commit(edit { $0.light.exposure = 1 + 1e-9 }, label: "jitter", now: t0))
        // 077（2026-10-27）: 末步换成**另一个参数**。原用例用 `exposure = 1 + 1e-3` 证明"过了容差就是
        // 一次真编辑"，而 077 规定同一 class 的连续提交**合并**成一行 —— 两条规则在同一个字段上必然
        // 冲突。断言（+1 行）保留，驱动换成 `color.vibrance`；紧接着补一句正面断言：同参数过容差
        // 仍然合并、`current` 跟着走（新旧两条规则同时钉住，谁坏了都红）。
        var real = h.current!
        real.color.vibrance = 1e-3
        XCTAssertNotNil(h.commit(real, label: "real", now: t0))
        XCTAssertEqual(h.count, 3)

        var sameClass = real
        sameClass.color.vibrance = 2e-3
        let merged = h.commit(sameClass, label: "same class", now: t0)
        XCTAssertEqual(merged?.seq, h.snapshots.last?.seq, "同参数连拖：覆盖栈顶，seq 不变")
        XCTAssertEqual(h.count, 3, "同参数过容差仍是编辑（`current` 移动），但只有一行")
        XCTAssertEqual(h.current?.color.vibrance ?? 0, 2e-3, accuracy: 1e-12)
    }

    // MARK: ⑦ masks: empty and absent are the same

    func testEmptyAndMissingMasksDoNotDirtyTheMaskGroup() throws {
        let v = EditModel.currentSchemaVersion      // interpolated: the test tracks the schema
        // …and the process version, for the same reason: it is interpolated too, because a fixture
        // pinned at an older one is a version bump, and a version bump is *every* group dirty by
        // design (`dirtyGroups` compares documents, not parsers). The claim being made here is about
        // absent-vs-empty mask lists, which has nothing to do with either version.
        let p = EditModel.currentProcessVersion
        let minimal = try JSONDecoder().decode(
            EditModel.self, from: Data(#"{"schemaVersion":\#(v),"processVersion":\#(p)}"#.utf8))
        let explicitNull = try JSONDecoder().decode(
            EditModel.self, from: Data(#"{"schemaVersion":\#(v),"processVersion":\#(p),"masks":null}"#.utf8))
        let explicitEmpty = try JSONDecoder().decode(
            EditModel.self, from: Data(#"{"schemaVersion":\#(v),"processVersion":\#(p),"masks":[]}"#.utf8))

        XCTAssertEqual(minimal.masks, [])
        XCTAssertEqual(explicitNull.masks, [])
        XCTAssertEqual(explicitEmpty.masks, [])

        for (a, b) in [(minimal, explicitNull), (minimal, explicitEmpty),
                       (explicitNull, explicitEmpty), (minimal, EditModel.neutral)] {
            XCTAssertEqual(EditHistory.dirtyGroups(from: a, to: b), [],
                           "an absent mask list is an empty mask list, not a dirty group")
        }

        // a mask whose geometry changed is a masks-only change
        let a = edit { $0.masks = [Mask(id: "m-1", opacity: 0.5)] }
        let b = edit { $0.masks = [Mask(id: "m-1", opacity: 0.9)] }
        XCTAssertEqual(EditHistory.dirtyGroups(from: a, to: b), [.masks])
        XCTAssertEqual(EditHistory.dirtyGroups(from: a, to: edit { $0.masks = [Mask(id: "m-1", opacity: 0.5, refine: 0.8)] }),
                       [.masks], "refine is part of the atlas key")
        // an added and a removed mask are both mask changes
        XCTAssertEqual(EditHistory.dirtyGroups(from: EditModel.neutral, to: a), [.masks])
        XCTAssertEqual(EditHistory.dirtyGroups(from: a, to: EditModel.neutral), [.masks])
        // the same masks in a different order are a different combination
        let two = edit { $0.masks = [Mask(id: "m-1"), Mask(id: "m-2")] }
        let swapped = edit { $0.masks = [Mask(id: "m-2"), Mask(id: "m-1")] }
        XCTAssertEqual(EditHistory.dirtyGroups(from: two, to: swapped), [.masks])
        // mask float tolerance follows the canonical key resolution (1e-5): noise is clean, a real
        // edit is dirty
        let tuned = edit { $0.masks = [Mask(id: "m-1", opacity: 0.5)] }
        XCTAssertEqual(EditHistory.dirtyGroups(
            from: tuned, to: edit { $0.masks = [Mask(id: "m-1", opacity: 0.5 + 1e-9)] }), [])
        XCTAssertEqual(EditHistory.dirtyGroups(
            from: tuned, to: edit { $0.masks = [Mask(id: "m-1", opacity: 0.5 + 1e-3)] }), [.masks])
    }

    /// A rename must not redraw anything, and must still be undoable: dirty groups and "same
    /// document" are different questions, and `commit` asks the second one.
    func testMaskRenameIsNotDirtyButIsStillCommittable() {
        let before = edit { $0.masks = [Mask(id: "m-1", name: "Mask 1", opacity: 0.5)] }
        let renamed = edit { $0.masks = [Mask(id: "m-1", name: "Sky", opacity: 0.5)] }

        XCTAssertEqual(EditHistory.dirtyGroups(from: before, to: renamed), [],
                       "a name is in no cache key, so nothing needs recomputing")
        XCTAssertFalse(EditHistory.isSemanticallyIdentical(before, renamed),
                       "but the document did change")

        var h = EditHistory(baseline: before, label: "Original", maxDepth: 10, now: t0)
        XCTAssertNil(h.commit(before, label: "no-op", now: t0))
        XCTAssertNotNil(h.commit(renamed, label: "Rename mask", now: t0))
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h.undo()?.masks.first?.name, "Mask 1")
        XCTAssertEqual(h.redo()?.masks.first?.name, "Sky")
    }

    // MARK: jump

    func testJumpSelectsAnySnapshotWithoutTruncating() {
        var h = history()
        let a = edit { $0.light.exposure = 1 }
        let b = edit { $0.light.contrast = 20 }
        let c = edit { $0.color.saturation = 30 }
        h.commit(a, label: "Exposure", now: t0)
        h.commit(b, label: "Contrast", now: t0)
        h.commit(c, label: "Saturation", now: t0)
        let seqs = h.snapshots.map(\.seq)

        XCTAssertEqual(h.jump(to: seqs[0]), EditModel.neutral)
        XCTAssertEqual(h.cursor, 0)
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.count, 4)

        XCTAssertEqual(h.jump(to: seqs[2]), b)        // jumping forward is redo, not an edit
        XCTAssertEqual(h.count, 4)
        XCTAssertEqual(h.current, b)

        XCTAssertNil(h.jump(to: 999))                 // unknown seq changes nothing
        XCTAssertEqual(h.cursor, 2)

        XCTAssertEqual(h.jumpToTip(), c)
        XCTAssertEqual(h.cursor, 3)
        XCTAssertFalse(h.canRedo)

        // a jump back then a commit does truncate the branch that was ahead
        h.jump(to: seqs[1])
        h.commit(edit { $0.effects.grain = 25 }, label: "Grain", now: t0)
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.snapshots.map(\.seq), [0, 1, 4])   // 0…3 were taken; 4 is next free
    }

    // MARK: persistence

    func testCodableRoundTripPreservesStackAndCursor() throws {
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "Exposure", now: t0)
        h.commit(edit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.7), CurvePoint(u: 1, v: 1)] },
                 label: "Curve", now: t0)
        h.commit(edit { $0.color.saturation = 30 }, label: "Saturation", now: t0)
        h.undo()                                       // a mid-stack cursor must survive too
        XCTAssertTrue(h.canRedo)

        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(EditHistory.self, from: data)

        XCTAssertEqual(back, h)
        XCTAssertEqual(back.cursor, h.cursor)
        XCTAssertEqual(back.nextSeq, h.nextSeq)
        XCTAssertEqual(back.snapshots.map(\.seq), h.snapshots.map(\.seq))
        XCTAssertEqual(back.snapshots.map(\.label), h.snapshots.map(\.label))
        XCTAssertEqual(back.snapshots.map(\.edit), h.snapshots.map(\.edit))
        XCTAssertEqual(back.current, h.current)
        XCTAssertTrue(back.canRedo)

        // the encoded envelope is explicit, not incidental
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, EditHistory.currentSchemaVersion)
        XCTAssertEqual(obj["maxDepth"] as? Int, EditHistory.defaultMaxDepth)
        XCTAssertEqual(obj["cursor"] as? Int, h.cursor)
        XCTAssertEqual((obj["snapshots"] as? [[String: Any]])?.count, 4)   // baseline + 3 edits
        let firstSnapshot = try XCTUnwrap((obj["snapshots"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstSnapshot["label"] as? String, "Original")
        XCTAssertNotNil(firstSnapshot["createdAt"])
        XCTAssertNotNil(firstSnapshot["edit"])
    }

    func testDecodingAForgivingOrTruncatedEnvelope() throws {
        // empty object: a usable default rather than a decode failure
        let empty = try JSONDecoder().decode(EditHistory.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.schemaVersion, EditHistory.currentSchemaVersion)
        XCTAssertEqual(empty.maxDepth, EditHistory.defaultMaxDepth)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.cursor, 0)
        XCTAssertEqual(empty.nextSeq, 0)

        // a cursor past the end is clamped instead of trapping the next undo
        var h = history()
        h.commit(edit { $0.light.exposure = 1 }, label: "Exposure", now: t0)
        var obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(h)) as? [String: Any])
        obj["cursor"] = 99
        obj["maxDepth"] = 0
        let clamped = try JSONDecoder().decode(
            EditHistory.self, from: try JSONSerialization.data(withJSONObject: obj))
        var mutableClamped = clamped
        XCTAssertEqual(clamped.cursor, 0)              // the only survivor, after trimming
        XCTAssertEqual(clamped.maxDepth, 1)            // clamped ≥ 1, and depth trimming applied
        XCTAssertEqual(clamped.count, 1)
        XCTAssertEqual(clamped.current?.light.exposure, 1)
        XCTAssertNil(mutableClamped.undo())
    }

    func testInitFromRowsMatchesCursorSeq() {
        let a = edit { $0.light.exposure = 1 }
        let b = edit { $0.light.contrast = 20 }
        let rows = [
            EditHistory.Snapshot(seq: 0, label: "Original", edit: .neutral, createdAt: t0),
            EditHistory.Snapshot(seq: 1, label: "Exposure", edit: a, createdAt: t0),
            EditHistory.Snapshot(seq: 2, label: "Contrast", edit: b, createdAt: t0),
        ]

        let tip = EditHistory(rows: rows, maxDepth: 10)
        XCTAssertEqual(tip.cursor, 2)
        XCTAssertEqual(tip.current, b)
        XCTAssertEqual(tip.nextSeq, 3)

        let parked = EditHistory(rows: rows, cursorSeq: 1, maxDepth: 10)
        XCTAssertEqual(parked.cursor, 1)
        XCTAssertEqual(parked.current, a)
        XCTAssertTrue(parked.canRedo)

        // a cursor seq that no longer exists falls back to the tip, as "just saved" means
        let stale = EditHistory(rows: rows, cursorSeq: 42, maxDepth: 10)
        XCTAssertEqual(stale.cursor, 2)

        // unordered rows are sorted, and a new commit continues from the highest seq
        var shuffled = EditHistory(rows: [rows[2], rows[0], rows[1]], maxDepth: 10)
        XCTAssertEqual(shuffled.snapshots.map(\.seq), [0, 1, 2])
        let next = shuffled.commit(edit { $0.color.saturation = 3 }, label: "Color", now: t0)
        XCTAssertEqual(next?.seq, 3)
    }
}
