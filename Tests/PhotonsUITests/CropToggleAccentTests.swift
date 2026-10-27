import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ③ — 水平 / 垂直 / 九宫格 激活后应该是蓝色，现在看不出蓝.
///
/// The slot was already written (`bezelColor = .controlAccentColor`) and the assertion that read the
/// slot back was already green — which is exactly why the bug survived: `NSButton` paints
/// `bezelColor` only for the bezel styles that own a filled bezel, and these three are `.inline` (a
/// hairline inline bezel, so they sit in the HUD pill like the popup next to them). The colour was
/// set and nothing was drawn.
///
/// So the evidence here is **pixels from the real bar**, not a slot: the `CropToolBar` instance is
/// rendered off screen (`cacheDisplay`) and the buttons' own centre rows are sampled, one state at a
/// time. On ⇒ within 24/255 of `controlAccentColor` on every channel; off ⇒ the same value it has
/// today (the off baseline is captured from the same bar before anything is switched on, so "off is
/// unchanged" is a byte comparison, not a memory).
@MainActor
final class CropToggleAccentTests: XCTestCase {

    private var workDir: URL!
    private var window: NSWindow!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-accent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private struct RGB: Hashable {
        var r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
        func distance(to other: RGB) -> Int {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }
    }

    private func makeBar() throws -> (CropToolBar, CropToolController, CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let controller = CropToolController(session: session)
        let bar = CropToolBar(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        window.orderFront(nil)
        bar.controller = controller
        XCTAssertTrue(controller.begin())
        bar.sync()
        bar.layout(in: NSRect(x: 0, y: 0, width: 900, height: 600))
        bar.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.02)
        return (bar, controller, session)
    }

    /// The bar as a bitmap, at the window's own backing scale.
    ///
    /// `display()` before the cache: `cacheDisplay` re-uses whatever is already in the view's backing
    /// store, so a button whose state changed would otherwise be sampled in its **old** state (the
    /// first snapshot after a toggle read the previous frame; the 九宫格 — on since `build()` — was the
    /// only one that looked right).
    private func bitmap(of bar: CropToolBar) throws -> (rep: NSBitmapImageRep, scale: CGFloat) {
        bar.layoutSubtreeIfNeeded()
        // Every toggle is displayed **explicitly**: `NSView.display()` does not recurse into the
        // subviews, so a button whose state was just changed keeps its previous layer content and the
        // cache would sample the old state (h/v read (37,37,37) because of exactly that).
        for which in ["h", "v", "grid"] {
            let button = bar.toggleButton(which)
            button.needsDisplay = true
            button.display()
        }
        bar.display()
        // `bitmapImageRepForCachingDisplay` is the honest one: it is created in the **window's own**
        // space and scale, which is where the bar actually draws. An explicit sRGB rep renders the
        // layer's contents black (measured), so the expectation is resolved in the bitmap's space
        // instead — see `accent(in:)`.
        guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else {
            throw XCTSkip("no bitmap for the bar")
        }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / max(bar.bounds.width, 1))
    }

    /// The **most common** colour inside the button's face (the middle 60 % of its rows, so the
    /// rounded corners and the hairline do not vote), plus the exact pixel at its centre.
    ///
    /// A single centre *row* is not enough: an 18 pt button's centre row is mostly glyph, and the modal
    /// there is the antialiasing rather than the face (measured: the row read (37,37,37) while the face
    /// was accent — the glyphs happen to sit exactly on that row).
    private func faceColour(_ rep: NSBitmapImageRep, in rect: NSRect, scale: CGFloat)
        -> (modal: RGB, centre: RGB, pixels: Int) {
        var counts: [RGB: Int] = [:]
        let y0 = max(Int(((rect.minY + rect.height * 0.2) * scale).rounded()), 0)
        let y1 = min(Int(((rect.maxY - rect.height * 0.2) * scale).rounded()), rep.pixelsHigh - 1)
        let x0 = max(Int(((rect.minX + 1) * scale).rounded()), 0)
        let x1 = min(Int(((rect.maxX - 1) * scale).rounded()), rep.pixelsWide - 1)
        guard x1 > x0, y1 > y0 else { return (RGB(r: -1, g: -1, b: -1), RGB(r: -1, g: -1, b: -1), 0) }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let rgb = RGB(r: Int((c.redComponent * 255).rounded()),
                              g: Int((c.greenComponent * 255).rounded()),
                              b: Int((c.blueComponent * 255).rounded()))
                counts[rgb, default: 0] += 1
            }
        }
        let y = min(max(Int((rect.midY * scale).rounded()), 0), rep.pixelsHigh - 1)
        let modal = counts.max { $0.value < $1.value }?.key ?? RGB(r: -1, g: -1, b: -1)
        let centreX = min(max(Int((rect.midX * scale).rounded()), 0), rep.pixelsWide - 1)
        let centreColour = rep.colorAt(x: centreX, y: y)?.usingColorSpace(.sRGB)
        let centre = centreColour.map {
            RGB(r: Int(($0.redComponent * 255).rounded()),
                g: Int(($0.greenComponent * 255).rounded()),
                b: Int(($0.blueComponent * 255).rounded()))
        } ?? RGB(r: -1, g: -1, b: -1)
        return (modal, centre, counts.values.reduce(0, +))
    }

    /// The accent **in the bitmap's own colour space**.
    ///
    /// `cacheDisplay` renders into a bitmap whose space is the window's (Display P3 here, device-RGB
    /// family in general), and `NSColor.controlAccentColor` is a catalog colour that resolves *in the
    /// space it is drawn into*: painted into that bitmap it comes out (70, 143, 248), while the same
    /// call read back in sRGB is (0, 122, 255). Comparing across the two would report a 70/255 error
    /// for a pixel that is in fact the accent exactly, so the expectation is resolved the same way
    /// the drawing was.
    private func accent(in space: NSColorSpace?) -> RGB {
        let target = space ?? .sRGB
        let c = NSColor.controlAccentColor.usingColorSpace(target)
            ?? NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        return RGB(r: Int((c.redComponent * 255).rounded()),
                   g: Int((c.greenComponent * 255).rounded()),
                   b: Int((c.blueComponent * 255).rounded()))
    }

    private func frame(of which: String, in bar: CropToolBar) -> NSRect {
        bar.frame(ofToggle: which)
    }

    /// On = accent blue (pixels), off = the value it has today, and each of the three switches is
    /// independent of the other two.
    ///
    /// The order matters and is deliberate: 九宫格 starts **on**, so it is the first sample; every other
    /// snapshot switches exactly one control. Nothing is `pump`ed between a toggle and its snapshot —
    /// a run-loop turn lets the document observer reload the edit, which would answer a different
    /// question than the one being asked.
    func testTheThreeTogglesAreAccentBlueInPixels() throws {
        // The session is **held** here on purpose: `CropToolController.session` is `weak`, and the two
        // flips are document writes — with the session released, `toggleFlipHorizontal()` silently
        // returns false and the button never turns on (which is what this suite first measured).
        let (bar, controller, session) = try makeBar()
        _ = session
        defer { window.orderOut(nil) }

        func snapshot() throws -> (rep: NSBitmapImageRep, scale: CGFloat) { try bitmap(of: bar) }
        func face(_ image: (rep: NSBitmapImageRep, scale: CGFloat), _ which: String) -> RGB {
            faceColour(image.rep, in: frame(of: which, in: bar), scale: image.scale).modal
        }

        // 1. 九宫格 on (the default), the two flips off.
        var image = try snapshot()
        let accent = accent(in: image.rep.colorSpace)
        print("③ accent in the bitmap's space (\(image.rep.colorSpace.localizedName ?? "?")) "
              + "\(accent.description) · in sRGB \(self.accent(in: .sRGB).description)")
        let onlyGrid = ["grid": face(image, "grid"), "h": face(image, "h"), "v": face(image, "v")]

        // 2. 水平 on alone.
        controller.toggleGrid()
        controller.toggleFlipHorizontal()
        bar.sync()
        image = try snapshot()
        let onlyH = ["h": face(image, "h"), "grid": face(image, "grid"), "v": face(image, "v")]

        // 3. 垂直 on alone.
        controller.toggleFlipHorizontal()
        controller.toggleFlipVertical()
        bar.sync()
        image = try snapshot()
        let onlyV = ["v": face(image, "v"), "h": face(image, "h"), "grid": face(image, "grid")]

        // 4. Everything off — today's plain style, the baseline the ⑤ "off is unchanged" half needs.
        controller.toggleFlipVertical()
        bar.sync()
        image = try snapshot()
        let off = ["h": face(image, "h"), "v": face(image, "v"), "grid": face(image, "grid")]
        print("③ off (all three) · h \(off["h"]!.description) · v \(off["v"]!.description) · "
              + "grid \(off["grid"]!.description) · accent \(accent.description)")

        for (name, sample, onKey) in [("九宫格 on", onlyGrid, "grid"),
                                     ("水平 on", onlyH, "h"),
                                     ("垂直 on", onlyV, "v")] {
            let on = sample[onKey]!
            print("③ \(name) · 按钮中心区(中间 60% 行)众数 \(on.description) · 与 accent 距离 "
                  + "\(on.distance(to: accent)) · 其余: "
                  + sample.filter { $0.key != onKey }.map { "\($0.key) \($0.value.description)" }
                    .sorted().joined(separator: " · "))
            XCTAssertLessThanOrEqual(on.distance(to: accent), 24,
                                     "③ \(name): the face is \(on.description), not within 24/255 "
                                     + "of the accent \(accent.description)")
            for (key, other) in sample where key != onKey {
                XCTAssertGreaterThan(other.distance(to: accent), 24,
                                     "③ \(name): \(key) must stay off, but it is \(other.description)")
                XCTAssertEqual(other, off[key], "③ \(name): \(key) must keep today's colour")
            }
        }
    }
}
