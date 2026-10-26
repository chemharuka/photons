import XCTest
import AppKit
import SwiftUI
@testable import PhotonsUI

/// 派单 014: the inspector's shooting-information block.
///
/// Three claims, each with a number instead of an adjective:
///   · the strings — full line, every missing-slot combination, and the four equipment cases;
///   · the width — every `MarqueeText` row is the card content width, not its text width;
///   · the march — head + `…` at rest, a linear pass that stops exactly at `-(textWidth − width)`
///     and stays there, and no movement at all when the text already fits.
final class InspectorMetadataTests: XCTestCase {

    private let inspectorWidth: CGFloat = 330
    /// `330 − 2·12 (scroll inset) − 2·16 (card inset)`, the width every card's content gets.
    private var cardContentWidth: CGFloat { inspectorWidth - 2 * 12 - 2 * WorkspaceLayout.cardInsetH }

    // MARK: format rules

    func testParametersLinePinsEverySlotInOrder() {
        XCTAssertEqual(
            InspectorPhotoInfo.parameters(iso: 100, focalLength: 24, aperture: 2.8, shutter: "1/250"),
            "ISO 100 · 24 mm · f/2.8 · 1/250s")
        // 24.0 must not print as "24.0 mm", and f/8 must not print as "f/8.0".
        XCTAssertEqual(
            InspectorPhotoInfo.parameters(iso: 64, focalLength: 90, aperture: 8, shutter: "1/60s"),
            "ISO 64 · 90 mm · f/8 · 1/60s")
        XCTAssertEqual(
            InspectorPhotoInfo.parameters(iso: 3200, focalLength: 24.5, aperture: 1.4, shutter: "2"),
            "ISO 3200 · 24.5 mm · f/1.4 · 2s")
    }

    func testParametersLineKeepsAllFourSlotsWhenTheFileIsSilent() {
        XCTAssertEqual(InspectorPhotoInfo.parameters(iso: nil, focalLength: nil, aperture: nil, shutter: nil),
                       "ISO — · — mm · f/— · —")
        // One missing slot does not shorten the line: same separators, same order.
        XCTAssertEqual(InspectorPhotoInfo.parameters(iso: 100, focalLength: nil, aperture: 2.8, shutter: nil),
                       "ISO 100 · — mm · f/2.8 · —")
        XCTAssertEqual(InspectorPhotoInfo.parameters(iso: nil, focalLength: 35, aperture: nil, shutter: "1/125"),
                       "ISO — · 35 mm · f/— · 1/125s")
    }

    func testShutterAcceptsBothSpellings() {
        XCTAssertEqual(InspectorPhotoInfo.shutter("1/250"), "1/250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("1/250s"), "1/250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("  2 "), "2s")
        XCTAssertNil(InspectorPhotoInfo.shutter("   "))
        XCTAssertNil(InspectorPhotoInfo.shutter(nil))
    }

    /// The four cases the user pinned, character for character (separator ` · `, placeholders
    /// `未知相机` / `未知镜头`).
    func testEquipmentLineFourCases() {
        // both
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "Leica Camera AG", model: "Leica SL3",
                                                    lens: "Sigma 20-60 DG"),
                       "Leica SL3 · Sigma 20-60 DG")
        // camera only
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "Leica Camera AG", model: "Leica SL3", lens: nil),
                       "Leica SL3 · 未知镜头")
        // lens only
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: nil, model: nil, lens: "Sigma 20-60 DG"),
                       "未知相机 · Sigma 20-60 DG")
        // neither: one word, no separator, no second placeholder
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: nil, model: nil, lens: nil), "未知相机")
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "  ", model: nil, lens: "   "), "未知相机")
    }

    /// The make is a fallback, never a prefix: `Leica Camera AG · Leica SL3` is too long for 274 pt.
    func testCameraPrefersTheModelAndFallsBackToTheMake() {
        XCTAssertEqual(InspectorPhotoInfo.cameraName(make: "Leica Camera AG", model: "Leica SL3"), "Leica SL3")
        XCTAssertEqual(InspectorPhotoInfo.cameraName(make: "Leica Camera AG", model: nil), "Leica Camera AG")
        XCTAssertNil(InspectorPhotoInfo.cameraName(make: nil, model: "   "))
    }

    // MARK: width

    /// The three rows come out of a real `NSHostingView` at the default 330 pt inspector, so this is
    /// the width SwiftUI actually handed the `MarqueeRowView`s — not a constant read back from a
    /// constant.
    @MainActor
    func testInfoRowsTakeExactlyTheCardContentWidth() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: inspectorWidth, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let rows = Self.marqueeRows(in: host)
        XCTAssertEqual(rows.count, 3, "filename + shooting parameters + equipment")
        guard rows.count == 3 else { return }

        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.frame.width, cardContentWidth, accuracy: 0.5,
                           "row \(index) width \(row.frame.width) ≠ card content \(cardContentWidth)")
            XCTAssertEqual(row.lineHeight, 14, accuracy: 0.001, "one rhythm for all three rows")
        }
        print("MARQUEE width: inspector \(inspectorWidth) → card content \(cardContentWidth) pt; "
              + "rows \(rows.map { String(format: "%.1f", $0.frame.width) })")
        window.contentView = nil
    }

    // MARK: overflow / marquee

    func testLongTextTruncatesAndPlaysOnceToTheEnd() throws {
        let font = NSFont.systemFont(ofSize: 10)
        let long = "Vario-Elmarit-SL 1:2.8-4/24-90 ASPH. Leica Camera AG Wetzlar Germany"
        let row = MarqueeRowView(text: long, font: font, lineHeight: 14)
        row.frame = NSRect(x: 0, y: 0, width: cardContentWidth, height: 14)
        row.layout()

        XCTAssertTrue(row.isOverflowing)
        XCTAssertEqual(row.offset, 0, "at rest the row shows the head")
        XCTAssertTrue(row.truncatedText.hasSuffix("…"), "tail ellipsis at rest: \(row.truncatedText)")
        XCTAssertLessThan(row.truncatedText.count, long.count)

        let overflow = row.textWidth - cardContentWidth
        XCTAssertEqual(overflow, MarqueeLayout.overflow(textWidth: row.textWidth, width: cardContentWidth),
                       accuracy: 0.001)
        XCTAssertEqual(row.duration, MarqueeLayout.duration(overflow: overflow), accuracy: 0.0001)
        print("MARQUEE overflow: textWidth \(String(format: "%.1f", row.textWidth)) pt, width \(cardContentWidth) pt, "
              + "overflow \(String(format: "%.1f", overflow)) pt, duration \(String(format: "%.3f", row.duration)) s, "
              + "chars at rest \(row.truncatedText.count) of \(long.count)")

        // Hover: one pass, linear.
        row.setHovering(true)
        XCTAssertEqual(row.playCount, 1)
        XCTAssertTrue(row.isPlaying)

        row.advance(to: row.duration / 2)
        XCTAssertEqual(row.offset, -overflow / 2, accuracy: 0.5, "half the time is half the distance")

        row.advance(to: row.duration)
        XCTAssertEqual(row.offset, -overflow, accuracy: 0.001,
                       "end offset is exactly -(textWidth - width) = \(-(overflow))")
        XCTAssertFalse(row.isPlaying, "the timer stops at the end")
        let endOffset = row.offset

        // Only once: half a second later it is still parked on the last character.
        row.advance(to: row.duration + 0.5)
        XCTAssertEqual(row.offset, endOffset, accuracy: 0.001)
        XCTAssertFalse(row.isPlaying)
        XCTAssertEqual(row.playCount, 1)
        print("MARQUEE end: offset \(String(format: "%.1f", endOffset)) pt, expected \(String(format: "%.1f", -overflow)) pt, "
              + "playCount \(row.playCount), idle after +0.5 s offset \(String(format: "%.1f", row.offset)) pt")

        // Hover off: straight back to the head, and the ellipsis returns.
        row.setHovering(false)
        XCTAssertEqual(row.offset, 0)
        XCTAssertFalse(row.isPlaying)
        XCTAssertTrue(row.truncatedText.hasSuffix("…"))
    }

    func testShortTextNeverMovesAndNeverGetsAnEllipsis() {
        let font = NSFont.systemFont(ofSize: 10)
        let short = "ISO 100 · 24 mm · f/2.8 · 1/250s"
        let row = MarqueeRowView(text: short, font: font, lineHeight: 14)
        row.frame = NSRect(x: 0, y: 0, width: cardContentWidth, height: 14)
        row.layout()

        XCTAssertFalse(row.isOverflowing)
        XCTAssertEqual(row.truncatedText, short, "no ellipsis when it fits")
        XCTAssertEqual(row.duration, 0)

        row.setHovering(true)
        XCTAssertEqual(row.playCount, 0, "nothing to play")
        XCTAssertFalse(row.isPlaying)
        XCTAssertEqual(row.offset, 0)

        row.advance(to: 2.0)
        XCTAssertEqual(row.offset, 0)
        row.setHovering(false)
        XCTAssertEqual(row.offset, 0)
        print("MARQUEE fit: textWidth \(String(format: "%.1f", row.textWidth)) pt ≤ \(cardContentWidth) pt, "
              + "offset 0, no ellipsis")
    }

    /// The duration formula the report quotes, at both clamps.
    func testDurationClampsToFourTenthsAndThreeSeconds() {
        XCTAssertEqual(MarqueeLayout.duration(overflow: 6), 0.4, accuracy: 0.0001)     // 0.1 s → floor
        XCTAssertEqual(MarqueeLayout.duration(overflow: 60), 1.0, accuracy: 0.0001)    // 60 pt/s
        XCTAssertEqual(MarqueeLayout.duration(overflow: 600), 3.0, accuracy: 0.0001)   // 10 s → ceiling
        XCTAssertEqual(MarqueeLayout.duration(overflow: 0), 0, accuracy: 0.0001)
    }

    // MARK: helpers

    @MainActor
    private static func marqueeRows(in view: NSView) -> [MarqueeRowView] {
        var found: [MarqueeRowView] = []
        if let row = view as? MarqueeRowView { found.append(row) }
        for sub in view.subviews { found += marqueeRows(in: sub) }
        return found
    }

    /// The panel adds the unit exactly once, and it normalises legacy rows on the way (a library
    /// imported before `ShutterFormat` has `55924/44739201` in the shutter column).
    func testShutterRowNormalisesLegacyRatiosAndAddsOneUnit() {
        XCTAssertEqual(InspectorPhotoInfo.shutter("55924/44739201"), "1/800s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("31667/39583751"), "1/1250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("1/250"), "1/250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("2"), "2s")
        XCTAssertNil(InspectorPhotoInfo.shutter(""))
        XCTAssertNil(InspectorPhotoInfo.shutter(nil))
    }
}
