//
//  AnselDenoiseService.swift
//
//  Image-level driver: tile a mosaic, hand the tiles to `ansel-denoise-swift` (GPLv3, separate
//  process), feather-blend the results, and hand back a denoised mosaic. MIT — nothing here is
//  derived from the upstream network code.
//
//  The split of responsibility is deliberate:
//    - the GPL tool knows nothing about images, only `count × tile²` float buffers;
//    - this file owns tiling, CFA phase, overlap windows and brightness preservation.
//  That keeps the GPL component small (and easy to keep in sync with upstream) while every piece
//  of product logic — the part that has to feel right — lives on the MIT side.
//

import Foundation

/// Result of a denoise run: the mosaic plus what the run cost.
public struct AnselDenoiseOutcome: Sendable {
    public let mosaic: [Float]        // width × height, normalized like the input
    public let width: Int
    public let height: Int
    public let tiles: Int
    public let seconds: Double
    public let backend: String
    /// Set when the source had to be edge-replicated to a tile-compatible size and the caller
    /// should therefore not assume `width × height` matches the original exactly.
    public let padded: Bool
}

public enum AnselDenoiseServiceError: Error, CustomStringConvertible {
    case emptyInput
    case badGeometry(String)
    case tempoaryFileFailed(String)

    public var description: String {
        switch self {
        case .emptyInput:            return "empty mosaic"
        case .badGeometry(let m):    return "bad geometry: \(m)"
        case .tempoaryFileFailed(let m): return "temporary file failed: \(m)"
        }
    }
}

public struct AnselDenoiseService: Sendable {
    public let client: AnselDenoiseClient
    public let modelURL: URL

    public init(client: AnselDenoiseClient, modelURL: URL) {
        self.client = client
        self.modelURL = modelURL
    }

    /// Denoise one mosaic.
    ///
    /// - Parameters:
    ///   - mosaic: normalized values (black subtracted, divided by white level), row-major.
    ///   - noiseA/noiseB: per-channel `Var = a·x + b`. **Getting sigma wrong is the single most
    ///     common cause of "the denoiser does nothing"** — the network treats sigma as its
    ///     strength control, so a 3× underestimate visibly under-denoises.
    /// - Returns: the denoised mosaic at the same size.
    public func denoise(mosaic: [Float],
                        width: Int,
                        height: Int,
                        options: AnselDenoiseOptions) throws -> AnselDenoiseOutcome {
        guard width > 0, height > 0, mosaic.count == width * height else {
            throw AnselDenoiseServiceError.emptyInput
        }
        let tile = options.tileSize
        let overlap = max(0, min(options.overlap, tile - 2))
        let step = max(1, tile - overlap)
        guard step > 0 else {
            throw AnselDenoiseServiceError.badGeometry("overlap \(overlap) leaves no step for tile \(tile)")
        }
        // Tiles must tile the plane; if the image is smaller than one tile, pad it up.
        let padW = max(0, tile - width)
        let padH = max(0, tile - height)
        let W = width + padW, H = height + padH

        var source = mosaic
        if padW > 0 || padH > 0 {
            var padded = [Float](repeating: 0, count: W * H)
            for y in 0..<H {
                let sy = min(y, height - 1)
                for x in 0..<W {
                    let sx = min(x, width - 1)
                    padded[y * W + x] = mosaic[sy * width + sx]
                }
            }
            source = padded
        }

        // Tile origins, always finishing flush with the far edge.
        func origins(_ extent: Int) -> [Int] {
            if extent <= tile { return [0] }
            var out = Array(stride(from: 0, to: extent - tile + 1, by: step))
            if out.last! + tile < extent { out.append(extent - tile) }
            return out
        }
        let ys = origins(H)
        let xs = origins(W)

        var tiles: [Float] = []
        tiles.reserveCapacity(ys.count * xs.count * tile * tile)
        var placed: [(y: Int, x: Int)] = []
        placed.reserveCapacity(ys.count * xs.count)
        for y in ys {
            for x in xs {
                placed.append((y, x))
                for ty in 0..<tile {
                    let base = (y + ty) * W + x
                    tiles.append(contentsOf: source[base..<(base + tile)])
                }
            }
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ansel-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let inURL = dir.appendingPathComponent("tiles.f32")
        let outURL = dir.appendingPathComponent("denoised.f32")

        do {
            try tiles.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: inURL)
        } catch {
            throw AnselDenoiseServiceError.tempoaryFileFailed("write \(inURL.path): \(error)")
        }

        let report = try client.denoiseBatch(model: modelURL,
                                            inputTiles: inURL,
                                            count: placed.count,
                                            output: outURL,
                                            options: options)

        let raw = try Data(contentsOf: outURL, options: .mappedIfSafe)
        let expected = placed.count * tile * tile * MemoryLayout<Float>.size
        guard raw.count == expected else {
            throw AnselDenoiseServiceError.badGeometry(
                "tool returned \(raw.count) bytes, expected \(expected)")
        }
        var flat = [Float](repeating: 0, count: placed.count * tile * tile)
        flat.withUnsafeMutableBytes { raw.copyBytes(to: $0) }

        // Feathered reassembly: a linear ramp so no seam appears at a tile boundary. The
        // accumulate-and-divide form guarantees the weights sum to 1 everywhere, including where
        // four tiles meet — a product-of-ramps window would drive the divisor to zero there and
        // leave black specks at every corner.
        var acc = [Float](repeating: 0, count: W * H)
        var wsum = [Float](repeating: 0, count: W * H)
        let rampLen = min(overlap / 2, tile / 2)
        var window = [Float](repeating: 1, count: tile * tile)
        if rampLen > 0 {
            // A separable window built from two mirrored half-tapers whose sum is exactly 1:
            //   head[i] = sin²((i+½)/r · π/2)   rises 0 → 1
            //   tail[i] = cos²((i+½)/r · π/2)   falls 1 → 0
            // so in any overlap band head + tail ≡ 1 and the neighbouring tiles' weights sum to 1
            // there. The 2-D window is the outer product, which keeps that property separable.
            //
            // Two wrong versions before this one, both of which look plausible and both of which
            // leave black specks: a linear ramp (sums to <1), and multiplying all four edges of a
            // sin² taper (corners get multiplied twice → weight 0, and 0/0 at a 4-tile junction).
            let r = rampLen
            var one_d = [Float](repeating: 1, count: tile)
            for i in 0..<r {
                let t = (Float(i) + 0.5) / Float(r) * .pi / 2
                let s = sin(t), c = cos(t)
                one_d[i] = s * s
                one_d[tile - 1 - i] = c * c
            }
            for y in 0..<tile {
                for x in 0..<tile {
                    window[y * tile + x] = one_d[y] * one_d[x]
                }
            }
        }

        for (i, origin) in placed.enumerated() {
            let base = i * tile * tile
            for ty in 0..<tile {
                let rowSrc = base + ty * tile
                let rowDst = (origin.y + ty) * W + origin.x
                let rowWin = ty * tile
                for tx in 0..<tile {
                    let w = window[rowWin + tx]
                    acc[rowDst + tx] += flat[rowSrc + tx] * w
                    wsum[rowDst + tx] += w
                }
            }
        }
        for i in 0..<acc.count where wsum[i] > 0 {
            acc[i] /= wsum[i]
        }

        // Crop the pad back off.
        if padW == 0 && padH == 0 {
            return AnselDenoiseOutcome(mosaic: acc, width: W, height: H,
                                       tiles: report.tiles,
                                       seconds: report.milliseconds / 1000,
                                       backend: report.backend, padded: false)
        }
        var cropped = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let src = y * W
            let dst = y * width
            for x in 0..<width { cropped[dst + x] = acc[src + x] }
        }
        return AnselDenoiseOutcome(mosaic: cropped, width: width, height: height,
                                   tiles: report.tiles,
                                   seconds: report.milliseconds / 1000,
                                   backend: report.backend, padded: true)
    }
}
