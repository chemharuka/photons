import XCTest
import AppKit
import SwiftUI
import PhotonsCore
@testable import PhotonsUI

/// ③（082 迁移）— 水平 / 垂直 / 九宫格 激活后是**系统强调色**，关掉时是它原来的样子.
///
/// 082 把这三片开关从画布底部的悬浮栏搬进了裁切卡的四个分区（`CropChip`），所以像素证据跟着控件
/// 搬到 `CropChip` 自己身上：这里把**这个控件**宿主进一扇真窗口，`cacheDisplay` 分别取「开」「关」
/// 两种状态的中心区众数，再和系统强调色比。删掉 `CropChip.fill(on:)` 里的强调色，这条必红。
///
/// 颜色空间那一课（060/072 的老账，仍然有效）：`cacheDisplay` 用的位图是**窗口自己的**色彩空间
/// （这台机器是 Display P3），而 `NSColor.controlAccentColor` 是 catalog 颜色、在**被画进的**空间里
/// 解析 —— 画进 P3 位图读出来是 (70,143,248)，同一个调用在 sRGB 里读是 (0,122,255)。所以期望值按
/// 位图的色彩空间解析，否则会把「完全正确的强调色」报成 70/255 的误差。
@MainActor
final class CropToggleAccentTests: XCTestCase {

    private var window: NSWindow?

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
    }

    private struct RGB: Hashable {
        var r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
        func distance(to other: RGB) -> Int {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }
    }

    /// The chip, hosted at its real size, as a bitmap at the window's backing scale.
    private func render(on: Bool) throws -> (rep: NSBitmapImageRep, scale: CGFloat, bounds: NSRect) {
        let size = NSSize(width: 64, height: CropChip.height)
        let host = NSHostingView(rootView: CropChip(title: "水平", on: on, help: "") {})
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + 8),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        host.layoutSubtreeIfNeeded()
        host.display()
        CropUITestSupport.pump(0.05)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("no bitmap for the chip")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / max(host.bounds.width, 1), host.bounds)
    }

    /// The **most common** colour inside the chip's face (the middle 60 % of its rows, so the rounded
    /// corners and the hairline do not vote). A single centre row is not enough: an 18 pt chip's centre
    /// row is mostly glyph, and the modal there is antialiasing rather than the face.
    private func faceColour(_ rep: NSBitmapImageRep, in rect: NSRect, scale: CGFloat) -> RGB {
        var counts: [RGB: Int] = [:]
        let y0 = max(Int(((rect.minY + rect.height * 0.2) * scale).rounded()), 0)
        let y1 = min(Int(((rect.maxY - rect.height * 0.2) * scale).rounded()), rep.pixelsHigh - 1)
        let x0 = max(Int(((rect.minX + 1) * scale).rounded()), 0)
        let x1 = min(Int(((rect.maxX - 1) * scale).rounded()), rep.pixelsWide - 1)
        guard x1 > x0, y1 > y0 else { return RGB(r: -1, g: -1, b: -1) }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let rgb = RGB(r: Int((c.redComponent * 255).rounded()),
                              g: Int((c.greenComponent * 255).rounded()),
                              b: Int((c.blueComponent * 255).rounded()))
                counts[rgb, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? RGB(r: -1, g: -1, b: -1)
    }

    /// The accent **in the bitmap's own colour space** (see this file's header).
    private func accent(in space: NSColorSpace?) -> RGB {
        let target = space ?? .sRGB
        let c = NSColor.controlAccentColor.usingColorSpace(target)
            ?? NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        return RGB(r: Int((c.redComponent * 255).rounded()),
                   g: Int((c.greenComponent * 255).rounded()),
                   b: Int((c.blueComponent * 255).rounded()))
    }

    /// On = the accent, off = not the accent (the card's material shows through, i.e. the fill is clear).
    func testTheChipIsAccentOnlyWhenOn() throws {
        let on = try render(on: true)
        let onFace = faceColour(on.rep, in: on.bounds, scale: on.scale)
        let accent = accent(in: on.rep.colorSpace)
        let onSRGB = self.accent(in: .sRGB)
        print("③ accent in the bitmap's space (\(on.rep.colorSpace.localizedName ?? "?")) "
              + "\(accent.description) · in sRGB \(onSRGB.description) · chip(on) face \(onFace.description)")
        XCTAssertLessThanOrEqual(onFace.distance(to: accent), 24,
                                 "③ 开着的 chip 必须是强调色：face \(onFace) vs accent \(accent)")

        let off = try render(on: false)
        let offFace = faceColour(off.rep, in: off.bounds, scale: off.scale)
        print("③ chip(off) face \(offFace.description) · distance to accent "
              + "\(offFace.distance(to: accent))")
        XCTAssertGreaterThan(offFace.distance(to: accent), 24,
                             "③ 关着的 chip 不许是强调色：face \(offFace)")

        // …and the colour decision itself is a function, so a literal cannot sneak in.
        XCTAssertEqual(CropChip.fill(on: true), Color.accentColor)
        XCTAssertEqual(CropChip.fill(on: false), Color.clear)
    }
}
