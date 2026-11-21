//
//  BuiltinDenoiseJob.swift
//
//  The file-to-file half of §480: DNG → four CFA planes → `BuiltinDenoise` (Anscombe + two-pass
//  NLM) → DNG. Naming, temp-file discipline and the report shape are deliberately the same as
//  `AnselDenoiseJob` / `NLMFDenoiseJob`; `CatalogSession` therefore keeps one stacking path.
//
//  Why the input is the file's mosaic, not a `CIRAWFilter` RGB buffer
//  ----------------------------------------------------------------
//  The ADR's rule is about the *display* pipeline: `CIRAWFilter` hands back demosaiced RGB, so a
//  renderer cannot reach the mosaic. This job is a file-to-file operation and already owns a mosaic
//  decoder (`SourceDNGDecode.readMosaic`) because `DNGRawWriter` writes CFA samples; feeding those
//  four planes is LightCraft's own input (R/G1/G2/B), not an approximation of it. The RGB adapter in
//  `BuiltinDenoise.fourPlanesFromRGB` exists for callers that really hold an RGB buffer, and its
//  unit test pins the noise normalisation.
//

import Foundation
import PhotonsLocalization

/// One DNG in, `<原名>-denoised.dng` out. Blocking; the caller owns the background queue.
public struct BuiltinDenoiseJob: Sendable {

    public struct Options: Sendable {
        /// 0…100, LightCraft's Amount: `original + amount/100 · (cleaned − original)`.
        public var amount: Double
        /// Plane-tile side and the cells neighbouring tiles share (LightCraft: 256 / 16).
        public var tileSize: Int
        public var overlap: Int
        /// Reverse-gate switch for the acceptance measurement: `false` computes every NLM weight on
        /// the raw values instead of the Anscombe-stabilised ones. Default `true`.
        public var anscombe: Bool
        public var tuning: BuiltinDenoise.Tuning
        /// Skip the per-file estimate and use these `(a, b)` (variance = a·signal + b).
        public var noise: (a: Float, b: Float)?

        public init(amount: Double = 100,
                    tileSize: Int = 256,
                    overlap: Int = 16,
                    anscombe: Bool = true,
                    tuning: BuiltinDenoise.Tuning = BuiltinDenoise.Tuning(),
                    noise: (a: Float, b: Float)? = nil) {
            self.amount = amount
            self.tileSize = tileSize
            self.overlap = overlap
            self.anscombe = anscombe
            self.tuning = tuning
            self.noise = noise
        }
    }

    public struct Report: Sendable {
        public let width: Int
        public let height: Int
        public let cfa: String
        public let tiles: Int
        public let seconds: Double
        public let byteCount: Int
        public let whiteLevel: Double
        public let blackLevels: [Double]
        public let noiseA: Float
        public let noiseB: Float
        public let output: URL
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case notADNG(String)
        case decode(String)
        case noCFA
        case emptyImage
        case write(String)

        public var description: String {
            switch self {
            case .notADNG(let name): return Loc.t("只支持 DNG：{0}", String(describing: (name)))
            case .decode(let message): return Loc.t("解码 RAW 失败：{0}", String(describing: (message)))
            case .noCFA: return Loc.t("DNG 没有可识别的 CFA 相位")
            case .emptyImage: return Loc.t("DNG 没有像素")
            case .write(let message): return Loc.t("产物落盘失败：{0}", String(describing: (message)))
            }
        }
    }

    /// Run one file. The output path is the caller's temporary name; the executor renames it.
    public func denoise(input: URL,
                        output: URL,
                        progress: (@Sendable (String) -> Void)? = nil) throws -> Report {
        let started = Date()
        let fm = FileManager.default
        guard input.pathExtension.lowercased() == "dng", fm.fileExists(atPath: input.path) else {
            throw Failure.notADNG(input.lastPathComponent)
        }

        let doc: SourceDNG
        let data: Data
        do {
            data = try Data(contentsOf: input, options: .alwaysMapped)
            doc = try SourceDNG(data: data)
        } catch {
            throw Failure.decode(error.localizedDescription)
        }
        guard let cfa = Self.cfaPattern(of: doc) else { throw Failure.noCFA }

        let mosaic: (samples: [UInt16], width: Int, height: Int)
        do {
            mosaic = try doc.readMosaic(data: data)
        } catch {
            throw Failure.decode(error.localizedDescription)
        }
        guard mosaic.width > 1, mosaic.height > 1,
              mosaic.samples.count == mosaic.width * mosaic.height else {
            throw Failure.emptyImage
        }

        let width = mosaic.width
        let height = mosaic.height
        let pw = width / 2
        let ph = height / 2
        guard pw > 2, ph > 2 else { throw Failure.emptyImage }

        let white = Self.whiteLevel(of: doc)
        let blacks = Self.blackLevels(of: doc)
        let channel = Self.channelIndex(cfa: cfa)

        progress?(Loc.t("读取 RAW {0}×{1}…", String(describing: (width)), String(describing: (height))))

        // Four planes, normalised by each CFA site's own black/white level.
        var planes = [[Float]](repeating: [Float](repeating: 0, count: pw * ph), count: 4)
        for c in 0..<4 {
            let (dx, dy) = (c % 2, c / 2)
            let black = Self.blackLevel(for: c, channel: channel, levels: blacks)
            let span = Double(white) - black
            let scale: Float = span > 0 ? Float(1 / span) : 1
            let b = Float(black)
            for y in 0..<ph {
                let srcRow = (2 * y + dy) * width
                let dstRow = y * pw
                for x in 0..<pw {
                    let v = Float(mosaic.samples[srcRow + 2 * x + dx]) - b
                    planes[c][dstRow + x] = min(max(v * scale, 0), 1)
                }
            }
        }

        progress?(Loc.t("估计噪声…"))
        let measured = options.noise ?? BuiltinDenoise.estimateNoise(planes: planes, width: pw, height: ph)
        let noise = max(measured.b, BuiltinDenoise.minVariance)

        let st = BuiltinDenoise.Stabiliser(a: measured.a, b: noise)
        let stabilise = options.anscombe
        if stabilise {
            for c in 0..<4 {
                for i in 0..<planes[c].count { planes[c][i] = st.forward(planes[c][i]) }
            }
        }

        let amount = Float(min(max(options.amount, 0), 100) / 100)
        let tile = max(32, min(options.tileSize, 512))
        let overlap = max(0, min(options.overlap, tile / 2))
        let step = max(1, tile - overlap)
        // Halo: run the filter on `tile + 2·margin` and keep the centre. Without it a cell near a
        // tile edge is filtered from mirrored padding in one tile and from real neighbours in the
        // next, and the cross-fade has to hide a genuine difference (measured: 3e-4 of full scale).
        // With the halo both tiles compute the same window around a shared cell, so the seam is
        // exact, not merely smooth.
        let margin = max(options.tuning.search, max(options.tuning.search2, options.tuning.searchC))
            + max(options.tuning.half, options.tuning.half2) + 2
        let side = tile + 2 * margin
        var originsX: [Int] = []
        var x = 0
        while x < pw { originsX.append(x); x += step }
        var originsY: [Int] = []
        var y = 0
        while y < ph { originsY.append(y); y += step }
        let tiles = originsX.count * originsY.count

        progress?(Loc.t("内置降噪 {0}×{1}，{2} 个 tile…",
                        String(describing: (width)), String(describing: (height)),
                        String(describing: (tiles))))

        var out = [[Float]](repeating: [Float](repeating: 0, count: pw * ph), count: 4)
        var weights = [Float](repeating: 0, count: pw * ph)

        // One chunk of tiles at a time, on all cores; the blend is serial and cheap.
        let chunk = max(1, min(tiles, ProcessInfo.processInfo.activeProcessorCount * 2))
        var start = 0
        while start < tiles {
            let end = min(start + chunk, tiles)
            let count = end - start
            let stride = 4 * tile * tile
            var results = [Float](repeating: 0, count: count * stride)
            results.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: count) { index in
                    let i = start + index
                    let ox = originsX[i % originsX.count]
                    let oy = originsY[i / originsX.count]
                    var tilePlanes = [[Float]](repeating: [Float](repeating: 0, count: side * side), count: 4)
                    for c in 0..<4 {
                        for ty in 0..<side {
                            let sy = min(max(oy - margin + ty, 0), ph - 1)
                            let srcRow = sy * pw
                            let dstRow = ty * side
                            for tx in 0..<side {
                                tilePlanes[c][dstRow + tx] = planes[c][srcRow + min(max(ox - margin + tx, 0), pw - 1)]
                            }
                        }
                    }
                    var local = measured
                    if local.b <= BuiltinDenoise.minVariance * 1.5 && local.a <= 0 {
                        local = BuiltinDenoise.estimateNoise(planes: tilePlanes, t: side)
                    }
                    let tileNoise = max(local.b, BuiltinDenoise.minVariance)
                    let tileStrength = (local.a * 0.18 + tileNoise).squareRoot()
                    // Stabilisation was applied to the whole plane before tiling; the fallback
                    // estimate only chooses the strength, so a bad tile cannot tear the domain.
                    let cleaned = BuiltinDenoise.filter(planes: tilePlanes, t: side,
                                                        tuning: options.tuning,
                                                        noise: tileStrength)
                    let base = index * stride
                    for c in 0..<4 {
                        for ty in 0..<tile {
                            let src = (margin + ty) * side + margin
                            let dst = ty * tile
                            for tx in 0..<tile {
                                buffer[base + c * tile * tile + dst + tx] = cleaned[c][src + tx]
                            }
                        }
                    }
                }
            }

            for index in 0..<count {
                let i = start + index
                let ox = originsX[i % originsX.count]
                let oy = originsY[i / originsX.count]
                let base = index * stride
                for ty in 0..<tile {
                    let gy = oy + ty
                    if gy >= ph { break }
                    let wy = Self.taper(local: ty, origin: oy, length: tile, overlap: overlap, total: ph)
                    for tx in 0..<tile {
                        let gx = ox + tx
                        if gx >= pw { break }
                        let w = wy * Self.taper(local: tx, origin: ox, length: tile, overlap: overlap, total: pw)
                        if w <= 0 { continue }
                        let at = gy * pw + gx
                        for c in 0..<4 {
                            out[c][at] += results[base + c * tile * tile + ty * tile + tx] * w
                        }
                        weights[at] += w
                    }
                }
            }
            start = end
        }

        // Inverse transform, then Amount in the original (normalised) domain.
        for c in 0..<4 {
            for i in 0..<(pw * ph) {
                let w = weights[i]
                let filtered = w > 0 ? out[c][i] / w : planes[c][i]
                let original: Float
                let cleaned: Float
                if stabilise {
                    // `planes` now holds stabilised values; recover the original through the inverse.
                    original = st.inverse(planes[c][i])
                    cleaned = st.inverse(filtered)
                } else {
                    original = planes[c][i]
                    cleaned = filtered
                }
                let mixed = original + (cleaned - original) * amount
                out[c][i] = min(max(mixed, 0), 1)
            }
        }

        // Back to the mosaic: one sample per CFA site.
        var samples = mosaic.samples
        for c in 0..<4 {
            let (dx, dy) = (c % 2, c / 2)
            let black = Self.blackLevel(for: c, channel: channel, levels: blacks)
            let span = Double(white) - black
            for y in 0..<ph {
                let dstRow = (2 * y + dy) * width
                let srcRow = y * pw
                for x in 0..<pw {
                    let v = black + Double(out[c][srcRow + x]) * span
                    samples[dstRow + 2 * x + dx] = UInt16(min(max(v.rounded(), 0), 65535))
                }
            }
        }

        progress?(Loc.t("写入 DNG…"))
        do {
            let result = try DNGRawWriter.write(samples: samples, width: width, height: height,
                                                from: input, to: output)
            let seconds = Date().timeIntervalSince(started)
            return Report(width: width, height: height, cfa: cfa, tiles: tiles,
                          seconds: seconds, byteCount: result.byteCount,
                          whiteLevel: Double(white), blackLevels: blacks,
                          noiseA: measured.a, noiseB: noise, output: output)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    // MARK: - Tags

    /// `33422 CFAPattern` → `"rggb"` (position order: (0,0), (1,0), (0,1), (1,1)).
    static func cfaPattern(of doc: SourceDNG) -> String? {
        guard let entry = doc.raw[33422] ?? doc.ifd0[33422], entry.count == 4 else { return nil }
        let letters = entry.value.prefix(4).map { v -> Character in
            switch v {
            case 0: return "r"
            case 1: return "g"
            case 2: return "b"
            default: return "?"
            }
        }
        return letters.contains("?") ? nil : String(letters)
    }

    /// CFA position → 0 (R), 1 (G) or 2 (B), for a 3-entry black-level table.
    static func channelIndex(cfa: String) -> [Int] {
        cfa.map { letter -> Int in
            switch letter {
            case "r": return 0
            case "g": return 1
            default: return 2
            }
        }
    }

    static func blackLevels(of doc: SourceDNG) -> [Double] {
        guard let entry = doc.raw[50714] ?? doc.ifd0[50714] else { return [] }
        switch entry.type {
        case 3:
            return stride(from: 0, to: entry.value.count - 1, by: 2).map {
                Double(UInt16(entry.value[$0]) | (UInt16(entry.value[$0 + 1]) << 8))
            }
        case 4:
            return stride(from: 0, to: entry.value.count - 3, by: 4).map {
                Double(UInt32(entry.value[$0]) | (UInt32(entry.value[$0 + 1]) << 8)
                       | (UInt32(entry.value[$0 + 2]) << 16) | (UInt32(entry.value[$0 + 3]) << 24))
            }
        case 5:
            // RATIONAL: Leica/Adobe write `BlackLevel` as 131072/256, not as a SHORT.
            return stride(from: 0, to: entry.value.count - 7, by: 8).map {
                let num = Double(UInt32(entry.value[$0]) | (UInt32(entry.value[$0 + 1]) << 8)
                                 | (UInt32(entry.value[$0 + 2]) << 16) | (UInt32(entry.value[$0 + 3]) << 24))
                let den = Double(UInt32(entry.value[$0 + 4]) | (UInt32(entry.value[$0 + 5]) << 8)
                                 | (UInt32(entry.value[$0 + 6]) << 16) | (UInt32(entry.value[$0 + 7]) << 24))
                return den == 0 ? 0 : num / den
            }
        default:
            return []
        }
    }

    static func whiteLevel(of doc: SourceDNG) -> Int {
        guard let entry = doc.raw[50717] ?? doc.ifd0[50717], let value = entry.firstUInt32,
              value > 0 else { return 65535 }
        return Int(value)
    }

    static func blackLevel(for plane: Int, channel: [Int], levels: [Double]) -> Double {
        if levels.count >= 4 { return levels[plane] }
        if levels.count == 1 { return levels[0] }
        if levels.count == 3, plane < channel.count { return levels[channel[plane]] }
        return levels.first ?? 0
    }

    /// A linear 1 over the interior, falling to 0 over the last `overlap` cells at a tile border
    /// that is not the image border. Linear, not cosine: with `step = length − overlap` the two
    /// neighbouring ramps then sum to exactly 1 at every cell, so the cross-fade cannot leave a
    /// step. (A cosine ramp looks smoother but leaves a visible seam because its complement is not
    /// a constant sum.)
    static func taper(local: Int, origin: Int, length: Int, overlap: Int, total: Int) -> Float {
        guard overlap > 0 else { return 1 }
        var w: Float = 1
        if origin > 0 {
            w = min(w, (Float(local) + 0.5) / Float(overlap))
        }
        if origin + length < total {
            w = min(w, (Float(length - local) - 0.5) / Float(overlap))
        }
        return max(0, min(w, 1))
    }
}
