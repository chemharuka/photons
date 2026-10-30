import XCTest
import CoreGraphics
import CoreText
import CryptoKit
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 180 — 文字水印：preset 存储、四角布局、像素混合、增益图隔离。
///
/// 每条断言都配一条 `print` 打出实测数字；数字本身是断言，不是只打印给人看。
final class WatermarkTests: XCTestCase {

    /// main `72c53e5` 上量到的无水印 PNG 字节 SHA（同一个 fixture、同一个预设，用一份只在测试树里跑的
    /// 探针在 main 与分支上各导出两次，四个 SHA 全等）。合同是
    /// `testEmptyWatermarkIsByteIdenticalToTheUntouchedEncoderPath` 里 Batch 与 `Exporter.write`
    /// 的**相等**；这条常量是那次跨提交实测的记录，ImageIO 的输出变了它会红，届时重新量。
    static let baseSDRSHA = "20dc579a0fac1aa0b0d18b24c811cd1198a78976b119d6adc4318137107fd271"
    /// 同上，HEIC 增益图（`fixture(hdr: true)`）。
    static let baseHDRSHA = "f808e0001731b663d63eabb86d220d02896deaba28142f4a4eae93fe381676c6"

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-watermark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    /// 渐变 `(x/W, y/H, x*y/(W*H))`，alpha 1，Display P3（引擎只接受与预设一致的 primaries）。
    /// `hdr: true` 时附带 linear 伴随图：同尺寸，中心 1/4 区域乘 3，制造真实 headroom。
    private func fixture(width: Int = 640, height: Int = 480,
                         hdr: Bool = false) -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                let o = (y * width + x) * 4
                rgba[o] = Float16(u)
                rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(u * v)
                rgba[o + 3] = 1
            }
        }
        guard hdr else {
            return DisplayImage(width: width, height: height, rgba: rgba,
                                primaries: .displayP3, bitDepth: 8)
        }

        var linear = [Float16](repeating: 0, count: width * height * 4)
        let x0 = width / 4, x1 = width * 3 / 4
        let y0 = height / 4, y1 = height * 3 / 4
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let boost = (x >= x0 && x < x1 && y >= y0 && y < y1) ? 3.0 : 1.0
                linear[o] = Float16(srgbToLinear(Double(rgba[o])) * boost)
                linear[o + 1] = Float16(srgbToLinear(Double(rgba[o + 1])) * boost)
                linear[o + 2] = Float16(srgbToLinear(Double(rgba[o + 2])) * boost)
                linear[o + 3] = 1
            }
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: .displayP3, bitDepth: 8,
                            linear: LinearPixels(width: width, height: height,
                                                 rgba: linear, primaries: .displayP3))
    }

    private func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func sdrPreset(text: String = "",
                           position: WatermarkPosition = .bottomRight,
                           opacity: Double = 60) -> ExportPreset {
        ExportPreset(format: .png, bitDepth: 8, colorSpace: .displayP3,
                     sizingMode: .original, metadataLevel: .none,
                     watermarkText: text, watermarkPosition: position,
                     watermarkOpacity: opacity)
    }

    private func hdrPreset(text: String = "",
                           position: WatermarkPosition = .bottomRight,
                           opacity: Double = 60) -> ExportPreset {
        ExportPreset(format: .heic, quality: 0.95, bitDepth: 8, colorSpace: .displayP3,
                     hdr: HDRExport(gainMap: .iso, halfSize: true, headroom: .auto),
                     sizingMode: .original, metadataLevel: .none,
                     watermarkText: text, watermarkPosition: position,
                     watermarkOpacity: opacity)
    }

    private func freshDirectory(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func export(_ preset: ExportPreset, _ image: DisplayImage,
                        from directory: URL, name: String = "wm") throws -> URL {
        let report = BatchExporter.run(items: [ExportItem(id: "i", name: name)],
                                       preset: preset, outputDirectory: directory,
                                       render: { _, _ in image })
        return try XCTUnwrap(report.written.first?.fileURL,
                             "batch did not write: \(report.failures.map { $0.error ?? "?" })")
    }

    private func sha256(_ url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - pixel readback

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// RGBA8, row 0 = 图像顶行（和 `Watermark` 的 `rgba` 行序一致）。
    private func pixels(_ url: URL) throws -> Pixels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("ImageIO cannot read \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("cannot build the readback context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func rgbDiff(_ a: Pixels, _ b: Pixels, x: Int, y: Int) -> Int {
        let o = (y * a.width + x) * 4
        return abs(Int(a.bytes[o]) - Int(b.bytes[o]))
            + abs(Int(a.bytes[o + 1]) - Int(b.bytes[o + 1]))
            + abs(Int(a.bytes[o + 2]) - Int(b.bytes[o + 2]))
    }

    // MARK: - 1. empty watermark = the untouched path

    func testEmptyWatermarkIsByteIdenticalToTheUntouchedEncoderPath() throws {
        // SDR / PNG.
        let sdr = sdrPreset()
        let sdrDirectory = try freshDirectory("sdr")
        let sdrBatchURL = try export(sdr, fixture(), from: sdrDirectory)
        let sdrReferenceURL = sdrDirectory.appendingPathComponent("reference.png")
        try Exporter.write(fixture(), to: sdrReferenceURL, options: sdr.exportOptions,
                           metadata: ExportMetadataContext(level: sdr.metadataLevel))
        let sdrBatch = try sha256(sdrBatchURL)
        let sdrReference = try sha256(sdrReferenceURL)
        print("180.1 SDR batch SHA \(sdrBatch) · reference SHA \(sdrReference)")
        XCTAssertEqual(sdrBatch, sdrReference,
                       "无文字水印时 BatchExporter 必须与改动前的唯一出口逐字节一致")
        // main 72c53e5 的记录（合同是上面那条相等；这条只在 ImageIO 输出变化时才该更新）。
        XCTAssertEqual(sdrBatch, Self.baseSDRSHA, "main 72c53e5 的 SDR 基线")

        // HDR / HEIC 增益图。
        let hdr = hdrPreset()
        let hdrDirectory = try freshDirectory("hdr")
        let hdrBatchURL = try export(hdr, fixture(hdr: true), from: hdrDirectory)
        let hdrReferenceURL = hdrDirectory.appendingPathComponent("reference.heic")
        try Exporter.write(fixture(hdr: true), to: hdrReferenceURL, options: hdr.exportOptions,
                           metadata: ExportMetadataContext(level: hdr.metadataLevel))
        let hdrBatch = try sha256(hdrBatchURL)
        let hdrReference = try sha256(hdrReferenceURL)
        print("180.1 HDR batch SHA \(hdrBatch) · reference SHA \(hdrReference)")
        XCTAssertEqual(hdrBatch, hdrReference,
                       "HDR 增益图也不能因为水印为空而改变一个字节")
        XCTAssertEqual(hdrBatch, Self.baseHDRSHA, "main 72c53e5 的 HDR 基线")
    }

    // MARK: - 1b. opacity 0 / 放不下的文字：同样一个字节都不改

    func testOpacityZeroAndOversizedTextPaintNothing() throws {
        // opacity 0 且文字非空：预设激活判断为假，输出必须与「没有水印」逐字节相同。
        let plain = try sha256(export(sdrPreset(), fixture(), from: try freshDirectory("zero-plain")))
        let zero = try sha256(export(sdrPreset(text: "WM", opacity: 0), fixture(),
                                    from: try freshDirectory("zero")))
        print("180.1b opacity0 SHA \(zero) · no-watermark SHA \(plain)")
        XCTAssertEqual(zero, plain, "opacity = 0 必须一个字节都不改")
        XCTAssertEqual(zero, Self.baseSDRSHA, "opacity = 0 也是改动前那份文件")

        // 越界 1：内边距矩形装不下整行文字 ⇒ plan 为 nil，导出照样成功且像素不变。
        let longLine = String(repeating: "水印", count: 80)
        let oversized = Watermark.plan(for: ImageSize(width: 640, height: 480), text: longLine,
                                       position: .bottomRight, opacity: 100)
        // 越界 2：内边距比画布还宽（8 × 400 ⇒ 内边距 8，内缩矩形宽度 0）。
        let sliver = DisplayImage(width: 8, height: 400,
                                  rgba: [Float16](repeating: 1, count: 8 * 400 * 4),
                                  primaries: .displayP3, bitDepth: 8)
        let noRect = Watermark.plan(for: sliver.size, text: "W", position: .topLeft, opacity: 100)
        print("180.1b oversized plan nil \(oversized == nil) · sliver plan nil \(noRect == nil)")
        XCTAssertNil(oversized, "装不下的文字必须返回 nil（不画），而不是画到框外")
        XCTAssertNil(noRect, "内边距吃掉整个画布时必须不画")
        let sliverURL = try sha256(export(sdrPreset(text: "W"), sliver,
                                          from: try freshDirectory("sliver")))
        let sliverPlain = try sha256(export(sdrPreset(), sliver,
                                            from: try freshDirectory("sliver-plain")))
        XCTAssertEqual(sliverURL, sliverPlain, "越界水印也要逐字节不变")
    }

    // MARK: - 2. four corners

    func testEveryCornerChangesOnlyPixelsInsideItsPaddingRect() throws {
        let image = fixture()
        let plain = try pixels(export(sdrPreset(), image, from: try freshDirectory("plain")))
        let w = plain.width, h = plain.height
        let longEdge = max(w, h)
        let pad = Int((Double(longEdge) * 0.02).rounded())
        print("180.2 canvas \(w)×\(h) · pad \(pad)")

        for position in WatermarkPosition.allCases {
            // Å 是升部/g 是降部：这两个字形把行盒的四条边都顶满，贴边断言才有意义。
            let text = "Åg"
            let url = try export(sdrPreset(text: text, position: position, opacity: 100),
                                 image, from: try freshDirectory("corner-\(position.rawValue)"))
            let marked = try pixels(url)
            XCTAssertEqual(marked.width, w)
            XCTAssertEqual(marked.height, h)

            var minX = w, minY = h, maxX = -1, maxY = -1
            var changed = 0, outside = 0
            for y in 0..<h {
                for x in 0..<w where rgbDiff(plain, marked, x: x, y: y) > 0 {
                    changed += 1
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                    if x < pad || x >= w - pad || y < pad || y >= h - pad { outside += 1 }
                }
            }
            let bbox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let inset = -1.0
            let tolerated = CGRect(x: pad, y: pad, width: w - 2 * pad, height: h - 2 * pad)
                .insetBy(dx: inset, dy: inset)
            print("180.2 \(position.rawValue) bbox \(bbox) · pad \(pad) · outside \(outside) "
                  + "· changed \(changed)")

            XCTAssertGreaterThan(changed, 0, "\(position) 必须有 ink")
            XCTAssertEqual(outside, 0, "\(position) 改到了内边距之外")
            XCTAssertTrue(tolerated.contains(bbox), "\(position) bbox 超出 allowedRect±1: \(bbox)")

            let cx = bbox.midX, cy = bbox.midY
            switch position {
            case .topLeft: XCTAssertTrue(cx < CGFloat(w) / 2 && cy < CGFloat(h) / 2)
            case .topRight: XCTAssertTrue(cx > CGFloat(w) / 2 && cy < CGFloat(h) / 2)
            case .bottomLeft: XCTAssertTrue(cx < CGFloat(w) / 2 && cy > CGFloat(h) / 2)
            case .bottomRight: XCTAssertTrue(cx > CGFloat(w) / 2 && cy > CGFloat(h) / 2)
            }

            let leftGap = bbox.minX
            let rightGap = CGFloat(w) - bbox.maxX
            let topGap = bbox.minY
            let bottomGap = CGFloat(h) - bbox.maxY
            let horizontalGap = (position == .topLeft || position == .bottomLeft) ? leftGap : rightGap
            let verticalGap = (position == .topLeft || position == .topRight) ? topGap : bottomGap
            print("180.2 \(position.rawValue) edge gaps h \(horizontalGap) v \(verticalGap) "
                  + "· target \(pad)")
            XCTAssertEqual(Double(horizontalGap), Double(pad), accuracy: 2,
                           "\(position) 水平方向没有贴边")
            XCTAssertEqual(Double(verticalGap), Double(pad), accuracy: 2,
                           "\(position) 垂直方向没有贴边")
        }
    }

    // MARK: - 3. opacity scales the ink

    func testOpacityHalvesTheInk() throws {
        let image = fixture()
        let plain = try pixels(export(sdrPreset(), image, from: try freshDirectory("ink-plain")))
        let full = try pixels(export(sdrPreset(text: "WM", opacity: 100), image,
                                   from: try freshDirectory("ink-100")))
        let half = try pixels(export(sdrPreset(text: "WM", opacity: 50), image,
                                    from: try freshDirectory("ink-50")))

        func sum(_ a: Pixels, _ b: Pixels) -> Int {
            var total = 0
            for y in 0..<a.height {
                for x in 0..<a.width { total += rgbDiff(a, b, x: x, y: y) }
            }
            return total
        }
        let sum100 = sum(plain, full)
        let sum50 = sum(plain, half)
        let ratio = sum100 == 0 ? 0 : Double(sum50) / Double(sum100)
        print("180.3 Σ|Δ| opacity100 \(sum100) · opacity50 \(sum50) · ratio \(ratio)")
        XCTAssertGreaterThan(sum100, 0)
        XCTAssertTrue((0.4...0.6).contains(ratio), "50% 的水印墨量应约为 100% 的一半，实得 \(ratio)")
    }

    // MARK: - 4. real glyphs, no tofu

    func testChineseTextDrawsRealGlyphs() throws {
        let text = "© 吕耀 2026"
        let image = fixture()
        let plan = try XCTUnwrap(Watermark.plan(for: image.size, text: text,
                                               position: .bottomRight, opacity: 100))
        let plain = try pixels(export(sdrPreset(), image, from: try freshDirectory("glyph-plain")))
        let marked = try pixels(export(sdrPreset(text: text, opacity: 100), image,
                                    from: try freshDirectory("glyph")))

        var minX = plain.width, minY = plain.height, maxX = -1, maxY = -1
        var changed = 0
        for y in 0..<plain.height {
            for x in 0..<plain.width where rgbDiff(plain, marked, x: x, y: y) > 0 {
                changed += 1
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        let bbox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        XCTAssertGreaterThan(changed, 0)
        XCTAssertFalse(bbox.isEmpty)

        var diffs: [Double] = []
        var inside = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let d = rgbDiff(plain, marked, x: x, y: y)
                diffs.append(Double(d))
                if d > 0 { inside += 1 }
            }
        }
        let mean = diffs.reduce(0, +) / Double(max(diffs.count, 1))
        let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(diffs.count, 1))
        let fraction = Double(inside) / Double(max(diffs.count, 1))
        print("180.4 font \(plan.fontSize) · bbox \(bbox) · changed \(changed) "
              + "· variance \(variance) · ink fraction \(fraction)")

        XCTAssertGreaterThan(variance, 500, "字形内部应有笔画，而不是一整块实心")
        XCTAssertLessThan(fraction, 0.6, "bbox 里的 ink 不应占满整块")

        let line = Watermark.line(text, fontSize: plan.fontSize)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var glyphCount = 0, notdef = 0
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            glyphCount += n
            notdef += glyphs.filter { $0 == 0 }.count
        }
        print("180.4 glyphs \(glyphCount) · runs \(runs.count) · notdef \(notdef)")
        XCTAssertGreaterThan(glyphCount, 0)
        XCTAssertEqual(notdef, 0, "© 吕耀 2026 里出现了 glyph 0（豆腐块）")
    }

    // MARK: - 5. metadata / document isolation

    func testWatermarkStaysOutOfMetadataAndTheDocument() throws {
        let edit = EditModel()
        let item = ExportItem(id: "i", name: "meta", edit: edit)
        let preset = ExportPreset(format: .jpeg, quality: 0.9, writeXMP: true,
                                  sizingMode: .original, metadataLevel: .all,
                                  watermarkText: "© 吕耀", watermarkPosition: .bottomRight,
                                  watermarkOpacity: 60)
        let directory = try freshDirectory("meta")
        let report = BatchExporter.run(items: [item], preset: preset, outputDirectory: directory,
                                       render: { _, _ in self.fixture() })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        let fileText = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(fileText.contains("吕耀"), "水印文字不能漏进图片内嵌 XMP")

        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        var sidecarText = ""
        if FileManager.default.fileExists(atPath: sidecar.path) {
            sidecarText = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        }
        print("180.5 file has 吕耀 \(fileText.contains("吕耀")) · sidecar \(sidecar.lastPathComponent) "
              + "mirror \(sidecarText.contains("吕耀"))")
        XCTAssertFalse(sidecarText.contains("吕耀"), "水印文字不能漏进侧车 XMP")
        XCTAssertEqual(item.edit, edit, "水印不改文档（EditModel）")

        let presetText = String(decoding: try preset.data(), as: UTF8.self)
        XCTAssertTrue(presetText.contains("watermarkText"), "预设自己必须带得住水印文字")
        print("180.5 preset keys contain watermarkText \(presetText.contains("watermarkText")) "
              + "· watermarkPosition \(presetText.contains("watermarkPosition")) "
              + "· watermarkOpacity \(presetText.contains("watermarkOpacity"))")
    }

    // MARK: - 6. old preset stays old

    func testOldPresetWithoutWatermarkKeysStillDecodesAndReEncodes() throws {
        let old = Data(#"""
        {"format":"png","quality":0.92,"bitDepth":8,"colorSpace":"displayP3","writeXMP":false,"nameTemplate":"{name}"}
        """#.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: old)
        XCTAssertEqual(decoded.watermarkText, "")
        XCTAssertEqual(decoded.watermarkPosition, .bottomRight)
        XCTAssertEqual(decoded.watermarkOpacity, 60)
        XCTAssertFalse(decoded.isWatermarkActive)

        let reencoded = String(decoding: try decoded.data(), as: UTF8.self)
        print("180.6 old preset re-encode keys · "
              + "text \(reencoded.contains("watermarkText")) "
              + "· position \(reencoded.contains("watermarkPosition")) "
              + "· opacity \(reencoded.contains("watermarkOpacity"))")
        XCTAssertFalse(reencoded.contains("watermarkText"))
        XCTAssertFalse(reencoded.contains("watermarkPosition"))
        XCTAssertFalse(reencoded.contains("watermarkOpacity"))

        let marked = ExportPreset(format: .png, watermarkText: "© 吕耀",
                                  watermarkPosition: .topLeft, watermarkOpacity: 35)
        let back = try JSONDecoder().decode(ExportPreset.self, from: try marked.data())
        print("180.6 round-trip text \(back.watermarkText) · \(back.watermarkPosition.rawValue) "
              + "· \(back.watermarkOpacity)")
        XCTAssertEqual(back, marked)
    }

    // MARK: - 7. gain-map base only

    func testWatermarkOnlyTouchesTheBaseOfAGainMapExport() throws {
        let image = fixture(hdr: true)
        let plan = try XCTUnwrap(Watermark.plan(for: image.size, text: "WM",
                                               position: .bottomRight, opacity: 60))
        let marked = Watermark.apply(image, plan)
        let inputLinear = try XCTUnwrap(image.linear)
        let outputLinear = try XCTUnwrap(marked.linear)
        let sameLinear = inputLinear.width == outputLinear.width
            && inputLinear.height == outputLinear.height
            && zip(inputLinear.rgba, outputLinear.rgba).allSatisfy { $0.bitPattern == $1.bitPattern }
        let rgbaChanged = zip(image.rgba, marked.rgba).contains { $0.bitPattern != $1.bitPattern }
        print("180.7 unit linear identical \(sameLinear) · rgba changed \(rgbaChanged) "
              + "· primaries \(marked.primaries.rawValue) · bits \(marked.bitDepth)")
        XCTAssertTrue(sameLinear, "Watermark.apply 必须原样透传 linear")
        XCTAssertEqual(marked.primaries, image.primaries)
        XCTAssertEqual(marked.bitDepth, image.bitDepth)
        XCTAssertTrue(rgbaChanged)
        XCTAssertEqual(marked.width, image.width)
        XCTAssertEqual(marked.height, image.height)

        let directory = try freshDirectory("gainmap")
        let plainURL = try export(hdrPreset(), image, from: directory, name: "plain")
        let markedURL = try export(hdrPreset(text: "WM"), image, from: directory, name: "marked")
        let headroom = try XCTUnwrap(GainMapHEIC.readHeadroom(at: markedURL))
        print("180.7 gain-map headroom \(headroom)")
        XCTAssertGreaterThanOrEqual(headroom, 1.05, "加了水印之后仍是 HDR 增益图")

        let plain = try pixels(plainURL)
        let changedBase = try pixels(markedURL)
        XCTAssertEqual(plain.width, changedBase.width)
        XCTAssertEqual(plain.height, changedBase.height)
        var cornerChanged = 0
        var maxCornerDelta = 0
        let corner = CGRect(x: plain.width / 2, y: plain.height / 2,
                            width: plain.width / 2, height: plain.height / 2)
        for y in Int(corner.minY)..<Int(corner.maxY) {
            for x in Int(corner.minX)..<Int(corner.maxX) {
                let d = rgbDiff(plain, changedBase, x: x, y: y)
                if d > 30 { cornerChanged += 1 }
                maxCornerDelta = max(maxCornerDelta, d)
            }
        }
        print("180.7 base corner changed \(cornerChanged) · max Δ \(maxCornerDelta)")
        XCTAssertGreaterThan(cornerChanged, 0, "水印角上的基础图像素必须变了")
        XCTAssertGreaterThan(maxCornerDelta, 30)
    }
}
