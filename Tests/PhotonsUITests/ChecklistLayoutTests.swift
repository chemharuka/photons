import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// 038 — the checklist popover's layout, measured in **pixels**, before *and* after a row click.
///
/// The bug the owner hit: the popover looked right the instant it opened, and the moment any row was
/// ticked the whole list jumped to the lower left. It was not a drawing mistake in the row — it was
/// `layoutRows()` writing `origin = .zero` on the view `NSPopover` had placed at its frame's 13 pt
/// border inset (measured: `root.frame` went `(13, 13, 236, 368)` → `(0, 0, 236, 368)` on the first
/// click). Sizes agreed the whole time, which is why a "does the size match" assertion would have
/// missed it; the *origin* moved. So every test here measures **after a click**, and the regression
/// test compares the ink's position inside the popover frame across the click.
@MainActor
final class ChecklistLayoutTests: XCTestCase {

    // The design, as the task states it (038 §2).
    private static let boxLeft: CGFloat = 10
    private static let boxSide: CGFloat = 12
    private static let boxTextGap: CGFloat = 8
    private static let trailingInset: CGFloat = 12
    private static let rowHeight: CGFloat = 22
    private static let padding: CGFloat = 10

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    // MARK: - the regression: a click must not move anything

    /// The whole bar, the real popover, the production click path (`onChange` → `update` →
    /// `refreshOpenChecklists` → `reload`), which is the sequence that used to move the list.
    func testClickingADimensionRowDoesNotMoveTheChecklist() {
        let bar = makeBar()
        bar.openDimensionPopover()
        pump()

        let popover = bar.dimensionPopoverForLayoutTests
        let checklist = bar.dimensionChecklistForLayoutTests
        XCTAssertTrue(popover.isShown, "the popover must be on screen for this to mean anything")

        let shown = measure(popover: popover, checklist: checklist)
        print("[038] show     root.frame=\(shown.rootFrame) content=\(popover.contentSize) ink=\(shown.inkInPopoverFrame)")

        bar.performDimensionRow(at: 2)          // tick 相机
        pump()
        let ticked = measure(popover: popover, checklist: checklist)
        print("[038] clicked  root.frame=\(ticked.rootFrame) content=\(popover.contentSize) ink=\(ticked.inkInPopoverFrame)")

        bar.performDimensionRow(at: 2)          // and untick it again
        pump()
        let unticked = measure(popover: popover, checklist: checklist)
        print("[038] unticked root.frame=\(unticked.rootFrame) content=\(popover.contentSize) ink=\(unticked.inkInPopoverFrame)")

        XCTAssertTrue(popover.isShown, "036: ticking a row must not close the popover")
        assertSamePlace(shown, ticked, "after ticking 相机")
        assertSamePlace(shown, unticked, "after unticking 相机")

        // The checklist is pinned inside the popover's view, so its own frame origin is never the
        // popover frame's origin — the 13 pt inset is AppKit's, and nothing of ours writes it.
        XCTAssertEqual(checklist.checklistRoot.frame.origin, .zero,
                       "the checklist fills its container, so its frame origin is the container's")
        XCTAssertEqual(checklist.checklistRoot.frame.size, shown.hostedBounds.size,
                       "the checklist must be exactly as big as the popover's content view")
    }

    /// Same thing for a slot's value list (a different popover object, the same reload path).
    func testClickingAValueRowDoesNotMoveTheChecklist() {
        let bar = makeBar()
        bar.facetProvider = { _ in ["1", "2", "3", "5"] }
        bar.openSlotPopover(at: 0)              // 星级
        pump()

        let popover = bar.slotPopoverForLayoutTests
        let checklist = bar.slotChecklistForLayoutTests
        XCTAssertTrue(popover.isShown)
        let shown = measure(popover: popover, checklist: checklist)
        print("[038] slot show root.frame=\(shown.rootFrame) content=\(popover.contentSize) ink=\(shown.inkInPopoverFrame)")

        bar.performSlotRow(at: 2)               // tick 「2」
        pump()
        let ticked = measure(popover: popover, checklist: checklist)
        print("[038] slot click root.frame=\(ticked.rootFrame) content=\(popover.contentSize) ink=\(ticked.inkInPopoverFrame)")

        XCTAssertTrue(popover.isShown)
        assertSamePlace(shown, ticked, "after ticking 2★")
    }

    // MARK: - text sits on its row's centre

    func testTextInkIsVerticallyCentredInItsRow() {
        let controller = FilterChecklistController()
        let rows = [
            FilterChecklistRow(title: "星级", checked: true),
            FilterChecklistRow(title: "1  相机", checked: false),
            FilterChecklistRow(title: "85mm", checked: true),
            FilterChecklistRow(title: "LEICA SL3", checked: false),
            FilterChecklistRow(title: "全部不选", enabled: true, kind: .action),
            FilterChecklistRow(title: "本库无此数据", enabled: false, kind: .note),
        ]
        let (popover, _) = show(controller, rows: rows)

        let buttons = controller.checklistRoot.subviews.compactMap { $0 as? FilterChecklistRowButton }
        XCTAssertEqual(buttons.count, rows.count)

        for (index, button) in buttons.enumerated() {
            let title = rows[index].title
            // Text only: everything right of the tick box.
            guard let ink = inkBox(of: button, fromX: button.textOriginX - 0.5) else {
                return XCTFail("row \(index) 「\(title)」 drew no text")
            }
            let delta = abs(ink.midY - button.bounds.midY)
            print(String(format: "[038] 「%@」 ink=%@ centre=%.2f rowCentre=%.2f delta=%.2f",
                         title, NSStringFromRect(ink), ink.midY, button.bounds.midY, delta))
            XCTAssertLessThanOrEqual(delta, 0.5,
                                     "「\(title)」 ink centre \(ink.midY) vs row centre \(button.bounds.midY)")
            // Ink must stay inside the row it belongs to.
            XCTAssertGreaterThanOrEqual(ink.minY, 0, "「\(title)」 ink above its row")
            XCTAssertLessThanOrEqual(ink.maxY, button.bounds.maxY, "「\(title)」 ink below its row")
        }
        popover.performClose(nil)
    }

    // MARK: - the margins

    func testTickBoxAndTitleSitOnTheDesignMargins() {
        let controller = FilterChecklistController()
        let rows = [
            FilterChecklistRow(title: "85mm", checked: true),      // toggle, no slot prefix
            FilterChecklistRow(title: "50mm", checked: false),
            FilterChecklistRow(title: "全部焦距", kind: .action),
        ]
        let (popover, _) = show(controller, rows: rows)
        let buttons = controller.checklistRoot.subviews.compactMap { $0 as? FilterChecklistRowButton }
        let first = buttons[0]

        // 1. the row itself starts at the content padding
        XCTAssertEqual(first.frame.minX, Self.padding, accuracy: 0.01)
        XCTAssertEqual(first.frame.height, Self.rowHeight, accuracy: 0.01)
        XCTAssertEqual(first.bounds.width, FilterChecklistController.width - Self.padding * 2,
                       accuracy: 0.01, "a row spans the content width minus two paddings")

        // 2. the tick box: left edge 10 pt from the content's left, 12 × 12
        XCTAssertEqual(first.boxRect.minX, FilterChecklistRowButton.boxSide - Self.boxSide, accuracy: 0.01)
        XCTAssertEqual(first.boxRect.width, Self.boxSide, accuracy: 0.01)
        XCTAssertEqual(first.boxRect.height, Self.boxSide, accuracy: 0.01)
        let boxInk = inkBox(of: first, fromX: 0, toX: first.textOriginX - 1)
        XCTAssertNotNil(boxInk, "the tick box must be drawn")
        if let boxInk {
            let left = first.frame.minX + boxInk.minX
            print(String(format: "[038] box ink left=%.2f (design %.1f), size=%.2f×%.2f",
                         left, Self.boxLeft, boxInk.width, boxInk.height))
            XCTAssertEqual(left, Self.boxLeft, accuracy: 0.5, "tick box left edge")
            XCTAssertEqual(boxInk.midY, first.bounds.midY, accuracy: 0.5, "tick box vertically centred")
        }

        // 3. the title starts box.maxX + 8, and never runs into the right edge
        XCTAssertEqual(first.textOriginX, Self.boxSide + Self.boxTextGap, accuracy: 0.01)
        let textInk = inkBox(of: first, fromX: first.textOriginX - 0.5)
        XCTAssertNotNil(textInk)
        if let textInk {
            let left = first.frame.minX + textInk.minX
            print(String(format: "[038] text ink left=%.2f (design 30.0)", left))
            XCTAssertEqual(left, Self.boxLeft + Self.boxSide + Self.boxTextGap, accuracy: 1,
                           "title left edge is 10 + 12 + 8 from the content's left")
            XCTAssertGreaterThanOrEqual(first.bounds.maxX - (first.frame.minX + textInk.maxX),
                                        Self.trailingInset - 1,
                                        "at least 12 pt stays clear on the right")
        }

        // A title too long for the row is truncated *inside* the trailing reserve, never under it.
        controller.reload([
            FilterChecklistRow(title: "85mm 一枚特别特别长的镜头名字用来测量截断", checked: true),
        ])
        popover.contentSize = controller.requiredSize
        pump()
        let long = controller.checklistRoot.subviews.compactMap { $0 as? FilterChecklistRowButton }[0]
        if let ink = inkBox(of: long, fromX: long.textOriginX - 0.5) {
            print(String(format: "[038] long title ink right=%.2f rowRight=%.2f reserve=%.2f",
                         ink.maxX, long.bounds.maxX, long.bounds.maxX - ink.maxX))
            XCTAssertLessThanOrEqual(ink.maxX, long.bounds.maxX - Self.trailingInset + 1,
                                     "a truncated title must leave the 12 pt reserve clear")
        } else {
            XCTFail("the long title drew nothing")
        }
        popover.performClose(nil)
    }

    // MARK: - the three sizes agree, and stay agreeing

    func testContentSizePreferredSizeAndRootAgreeAfterShowAndAfterClick() {
        let bar = makeBar()
        bar.openDimensionPopover()
        pump()

        let popover = bar.dimensionPopoverForLayoutTests
        let checklist = bar.dimensionChecklistForLayoutTests
        assertSizesAgree(popover: popover, checklist: checklist, when: "after show")

        bar.performDimensionRow(at: 4)
        pump()
        assertSizesAgree(popover: popover, checklist: checklist, when: "after a click")

        // 036 leaves the popover open when five are full and the tenth row is greyed; a reload that
        // changes nothing must not change the geometry either.
        bar.performDimensionRow(at: 4)
        pump()
        assertSizesAgree(popover: popover, checklist: checklist, when: "after the second click")
    }

    /// A row-count change while the popover is up (the slot lists do this when the library gains a
    /// value) resizes the popover — the content must stay in its inset, not slide to the corner.
    func testRowCountChangeWhileShownKeepsTheContentInset() {
        let controller = FilterChecklistController()
        let (popover, anchorWindow) = show(controller, rows: (0..<3).map { FilterChecklistRow(title: "行 \($0)") })
        let inset = popover.contentViewController?.view.frame.origin
        let firstInk = measure(popover: popover, checklist: controller).inkInPopoverFrame
        print("[038] 3 rows: content=\(popover.contentSize) inset=\(String(describing: inset)) ink=\(String(describing: firstInk))")

        controller.reload((0..<24).map { FilterChecklistRow(title: "行 \($0)") })
        popover.contentSize = controller.requiredSize
        pump()
        let grown = measure(popover: popover, checklist: controller)
        print("[038] 24 rows: content=\(popover.contentSize) inset=\(String(describing: grown.hostedFrame.origin)) ink=\(grown.inkInPopoverFrame)")

        XCTAssertEqual(grown.hostedFrame.origin, inset, "growing must keep the content at its inset")
        XCTAssertEqual(controller.checklistRoot.frame.size, grown.hostedBounds.size)
        assertSizesAgree(popover: popover, checklist: controller, when: "after growing to 24 rows")
        XCTAssertEqual(popover.contentSize.height, controller.requiredSize.height, accuracy: 0.01)
        XCTAssertGreaterThan(popover.contentSize.height, 500, "24 rows really did grow the popover")

        controller.reload((0..<3).map { FilterChecklistRow(title: "行 \($0)") })
        popover.contentSize = controller.requiredSize
        pump()
        let shrunk = measure(popover: popover, checklist: controller)
        XCTAssertEqual(shrunk.hostedFrame.origin, inset, "shrinking must keep the content at its inset")
        assertSizesAgree(popover: popover, checklist: controller, when: "after shrinking back to 3 rows")

        popover.performClose(nil)
        anchorWindow.orderOut(nil)
    }

    /// `Esc` still arrives: it lives on the flipped checklist, and the popover now hosts the
    /// container instead, so the first responder has to be taken by the checklist itself.
    func testChecklistTakesFocusSoEscapeStillWorks() {
        let controller = FilterChecklistController()
        var cancelled = false
        controller.onCancel = { cancelled = true }
        let (popover, _) = show(controller, rows: [FilterChecklistRow(title: "星级")])
        pump()
        let root = controller.checklistRoot
        XCTAssertTrue(popover.isShown)
        XCTAssertTrue(root.window?.firstResponder === root,
                      "the checklist, not the plain container, must hold focus")
        controller.view.window?.makeFirstResponder(root)
        root.cancelOperation(nil)
        XCTAssertTrue(cancelled, "Esc reaches onCancel")
        popover.performClose(nil)
    }

    // MARK: - fixtures

    private func makeBar() -> FilterBarView {
        let bar = FilterBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = bar
        bar.frame = NSRect(x: 0, y: 0, width: 700, height: 120)
        window.orderFront(nil)
        windows.append(window)
        // The app's loop: a click writes through the session, the session calls back into `update`.
        bar.onChange = { [weak bar] next in bar?.update(filter: next, cameraKeys: []) }
        bar.facetProvider = { _ in [] }
        bar.update(filter: .none, cameraKeys: [])
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func show(_ controller: FilterChecklistController,
                      rows: [FilterChecklistRow]) -> (NSPopover, NSWindow) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSButton(title: "anchor", target: nil, action: nil)
        window.contentView = anchor
        anchor.frame = NSRect(x: 40, y: 60, width: 90, height: 24)
        window.orderFront(nil)
        windows.append(window)

        controller.reload(rows)
        popover.contentSize = controller.requiredSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        pump()
        return (popover, window)
    }

    // MARK: - measurements

    private struct Snapshot {
        let hostedFrame: NSRect
        let hostedBounds: NSRect
        let rootFrame: NSRect
        /// The checklist's ink, in the popover frame's coordinates — the place the user sees it.
        let inkInPopoverFrame: NSRect
    }

    private func measure(popover: NSPopover, checklist: FilterChecklistController) -> Snapshot {
        let hosted = checklist.view
        let root = checklist.checklistRoot
        let origin = root.frame.origin
        let ink = inkBox(of: root, fromX: 0) ?? .zero
        return Snapshot(hostedFrame: hosted.frame,
                        hostedBounds: hosted.bounds,
                        rootFrame: root.frame,
                        inkInPopoverFrame: ink.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// Position only: a tick rewrites a row's title (「全部星级」 becomes 「星级 2★」), so the ink's
    /// *width* is expected to change. Where it starts must not.
    private func assertSamePlace(_ a: Snapshot, _ b: Snapshot, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(b.inkInPopoverFrame.minX, a.inkInPopoverFrame.minX, accuracy: 0.5,
                       "\(context): the checklist moved horizontally", file: file, line: line)
        XCTAssertEqual(b.inkInPopoverFrame.minY, a.inkInPopoverFrame.minY, accuracy: 0.5,
                       "\(context): the checklist moved vertically", file: file, line: line)
        XCTAssertEqual(b.hostedFrame.origin, a.hostedFrame.origin,
                       "\(context): the popover moved its content view", file: file, line: line)
    }

    private func assertSizesAgree(popover: NSPopover, checklist: FilterChecklistController,
                                  when context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let required = checklist.requiredSize
        XCTAssertEqual(popover.contentSize.width, required.width, accuracy: 0.01,
                       "\(context): contentSize vs requiredSize", file: file, line: line)
        XCTAssertEqual(popover.contentSize.height, required.height, accuracy: 0.01,
                       "\(context): contentSize vs requiredSize", file: file, line: line)
        XCTAssertEqual(checklist.preferredContentSize, required,
                       "\(context): preferredContentSize vs requiredSize", file: file, line: line)
        let root = checklist.checklistRoot
        XCTAssertEqual(root.bounds.size, required,
                       "\(context): the checklist's bounds vs requiredSize", file: file, line: line)
        XCTAssertEqual(root.frame.size, checklist.view.bounds.size,
                       "\(context): the checklist vs the popover's content view", file: file, line: line)
        XCTAssertEqual(checklist.view.frame.size, required,
                       "\(context): the popover's content view vs requiredSize", file: file, line: line)
    }

    private func pump(_ seconds: TimeInterval = 0.35) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Ink bounding box of a view in its own points, measured from the bitmap's top-left. `fromX` /
    /// `toX` narrow the scan to a column range (so the tick box and the title are measured apart).
    private func inkBox(of view: NSView, fromX: CGFloat, toX: CGFloat? = nil) -> NSRect? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let background = rep.colorAt(x: 0, y: 0) else { return nil }
        let scale = CGFloat(w) / max(1, view.bounds.width)

        let lowX = max(0, min(w - 1, Int((fromX * scale).rounded())))
        let highX = toX.map { min(w - 1, max(lowX, Int(($0 * scale).rounded()))) } ?? (w - 1)

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in lowX...highX {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(colour.redComponent - background.redComponent)
                    + abs(colour.greenComponent - background.greenComponent)
                    + abs(colour.blueComponent - background.blueComponent)
                guard delta >= 0.02 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }
}
