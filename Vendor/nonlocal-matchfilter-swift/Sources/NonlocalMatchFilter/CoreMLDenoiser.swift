//
//  CoreMLDenoiser.swift
//
//  Runs the RawNIND raw->raw network (Sánchez-Beeckman & Buades, arXiv 2604.17453)
//  through Core ML.
//
//  The model's contract, which this file exists to satisfy:
//
//      input   mosaic  float32 [1, 8, T, T]
//              planes 0..3  the packed Bayer, channel order **R, G, B, G**
//              planes 4..7  per-pixel noise sigma, sqrt(max(a*x + b, 0))
//                           (one a,b pair per CFA channel)
//      output  rgb     float32 [1, 4, T, T]
//              a *denoised packed mosaic* in the same R, G, B, G order —
//              not camera RGB, and not demosaiced.
//
//  Note the geometry: the planes hold one sample per 2×2 cell, so a `T × T`
//  plane is a `2T × 2T` window of mosaic. A 512² .mlpackage therefore consumes
//  1024×1024 mosaic pixels per call.
//
//  Two things about this model are easy to get wrong, and both produce a
//  plausible-looking picture rather than an error:
//
//  1. **Channel order is RGBG, not R,G1,G2,B.** The upstream README says
//     "packed into 4 channels in RGBG format". With R,G1,G2,B the network
//     balances the channels it thinks it sees and the result comes back with a
//     magenta cast: measured on a Leica SL3 raw, out/in per plane was
//     0.99 0.72 0.99 3.23 in the wrong order and 1.00 1.00 1.00 1.00 in RGBG.
//  2. **The plane size is baked into the model.** A 512² graph rejects 1024²
//     input outright, so the tile has to match the .mlpackage.
//

import CoreML
import Foundation

public enum CoreMLError: Error, CustomStringConvertible {
    case cannotLoad(String)
    case wrongInputShape(name: String, expected: [Int], got: [Int])
    case predictionFailed(String)
    case badOutput(String)

    public var description: String {
        switch self {
        case .cannotLoad(let m): return "cannot load the Core ML model: \(m)"
        case .wrongInputShape(let n, let e, let g):
            return "model input \(n) expects \(e), the caller supplied \(g)"
        case .predictionFailed(let m): return "Core ML prediction failed: \(m)"
        case .badOutput(let m): return "unexpected model output: \(m)"
        }
    }
}

/// Where each of the four packed planes sits inside the 2×2 cell.
///
/// The model wants R, G, B, G — the second green being the one on the blue row —
/// so this maps a plane index to a (dy, dx) offset within the cell.
public struct PackedLayout: Sendable {
    /// (dy, dx) for planes 0..3, in the model's R, G, B, G order.
    public let offsets: [(Int, Int)]
    /// The CFA at (0,0), lowercase, row-major.
    public let cfa: String

    public init(cfa: String) {
        let p = Array(cfa.lowercased())
        precondition(p.count == 4, "cfa must be 4 characters, got \(cfa)")
        func first(_ c: Character) -> (Int, Int)? {
            for (i, ch) in p.enumerated() where ch == c { return (i / 2, i % 2) }
            return nil
        }
        guard let r = first("r"), let b = first("b") else {
            preconditionFailure("cfa \(cfa) has no red or no blue")
        }
        var greens: [(Int, Int)] = []
        for (i, ch) in p.enumerated() where ch == "g" { greens.append((i / 2, i % 2)) }
        precondition(greens.count == 2, "cfa \(cfa) does not have two greens")
        // Plane order: R, then the green sharing red's row, then B, then the other green.
        let gRedRow = greens.first { $0.0 == r.0 } ?? greens[0]
        let gBlueRow = greens.first { $0.0 == b.0 } ?? greens[1]
        self.offsets = [r, gRedRow, b, gBlueRow]
        self.cfa = cfa.lowercased()
    }
}

public final class CoreMLDenoiser {
    private let model: MLModel
    /// Side of the square plane the .mlpackage was traced for (mosaic window = 2× this).
    public let planeSide: Int
    public var mosaicWindow: Int { planeSide * 2 }
    public let layout: PackedLayout
    private let inputName: String
    private let outputName: String

    /// Reused across tiles.
    ///
    /// `MLMultiArray` allocation for an 8×512×512 float buffer is 8 MB; doing it
    /// per tile means 70 allocations plus 70 frees, and every `prediction` also
    /// keeps a reference to the previous output alive until it returns. Holding
    /// one of each for the life of the denoiser removes that churn.
    private let inputArray: MLMultiArray
    private let outputBuffer: UnsafeMutablePointer<Float>
    /// Scratch for the packed planes, so the pack loop writes straight into the
    /// array Core ML will read instead of into an intermediate `[Float]`.
    private var planes: UnsafeMutablePointer<Float>

    public init(mlpackage path: String, layout: PackedLayout) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let source = URL(fileURLWithPath: path)
        do {
            // A .mlpackage has to be compiled to a .mlmodelc before it can be
            // loaded; MLModel does not do that for you. Compiling on every run
            // costs a couple of seconds, so a compiled copy beside the package
            // is reused when it is newer than the package.
            let compiled = try Self.compiledURL(for: source)
            self.model = try MLModel(contentsOf: compiled, configuration: config)
        } catch let e as CoreMLError {
            throw e
        } catch {
            throw CoreMLError.cannotLoad("\(error)")
        }
        self.layout = layout

        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.multiArrayConstraint else {
            throw CoreMLError.cannotLoad("no array input")
        }
        let shape = constraint.shape.map { $0.intValue }
        guard shape.count == 4, shape[1] == 8, shape[2] == shape[3] else {
            throw CoreMLError.wrongInputShape(name: input.key,
                                             expected: [1, 8, 512, 512], got: shape)
        }
        self.planeSide = shape[2]
        self.inputName = input.key
        guard let output = model.modelDescription.outputDescriptionsByName.first else {
            throw CoreMLError.cannotLoad("no array output")
        }
        self.outputName = output.key

        guard planeSide % 2 == 0 else {
            throw CoreMLError.cannotLoad("plane side \(planeSide) is not even")
        }

        // Allocate the reusable buffers once.
        let T = shape[2]
        do {
            self.inputArray = try MLMultiArray(
                shape: [1, 8, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        } catch {
            throw CoreMLError.cannotLoad("cannot allocate the input buffer: \(error)")
        }
        self.planes = .allocate(capacity: 8 * T * T)
        self.planes.initialize(repeating: 0, count: 8 * T * T)
        self.outputBuffer = .allocate(capacity: 4 * T * T)
        self.outputBuffer.initialize(repeating: 0, count: 4 * T * T)
    }

    deinit {
        planes.deinitialize(count: 8 * planeSide * planeSide)
        planes.deallocate()
        outputBuffer.deinitialize(count: 4 * planeSide * planeSide)
        outputBuffer.deallocate()
    }

    /// A compiled `.mlmodelc` for `source`, compiling it once and caching it beside the package.
    ///
    /// `MLModel.compileModel` returns a temporary URL that the caller must keep;
    /// copying it next to the package makes the second run skip compilation
    /// (2 s for this graph).
    private static func compiledURL(for source: URL) throws -> URL {
        if source.pathExtension == "mlmodelc" { return source }

        let cacheDir = source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.deletingPathExtension().lastPathComponent).mlmodelc")
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDir.path) {
            if let a = try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
               let b = try? fm.attributesOfItem(atPath: cacheDir.path)[.modificationDate] as? Date,
               b >= a {
                return cacheDir
            }
            try? fm.removeItem(at: cacheDir)
        }

        let tmp = try MLModel.compileModel(at: source)
        try fm.copyItem(at: tmp, to: cacheDir)
        return cacheDir
    }

    /// Denoise one mosaic window of `2 * planeSide` pixels.
    ///
    /// - Parameters:
    ///   - mosaic: `(2T) × (2T)` samples in [0,1], row-major, window top-left at its (0,0).
    ///   - window: the window's side in mosaic pixels; must be `2 * planeSide`.
    ///   - shot: per-CFA-plane Poisson gains, in the model's R, G, B, G order.
    ///   - read: per-CFA-plane read variances, same order.
    ///   - into: destination of `window * window` samples, same layout.
    public func denoiseWindow(
        _ mosaic: UnsafePointer<Float>,
        window: Int,
        shot: [Double],
        read: [Double],
        into out: UnsafeMutablePointer<Float>
    ) throws {
        let T = planeSide
        let W = T * 2
        precondition(window == W, "window must be \(W) mosaic pixels, got \(window)")
        precondition(shot.count == 4 && read.count == 4, "need 4 noise pairs")

        packAndSigma(mosaic, into: planes, shot: shot, read: read)

        // Hand Core ML the buffer we just filled: a plain copy of 8 MB, no
        // allocation, no intermediate array.
        inputArray.dataPointer.assumingMemoryBound(to: Float.self)
            .update(from: planes, count: 8 * T * T)

        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw CoreMLError.predictionFailed("\(error)")
        }
        guard let outArray = result.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLError.badOutput("no \(outputName) in the prediction")
        }
        guard outArray.count == 4 * T * T else {
            throw CoreMLError.badOutput("output holds \(outArray.count), expected \(4 * T * T)")
        }

        unpack(outArray.dataPointer.assumingMemoryBound(to: Float.self),
               into: out, window: W)
    }

    /// Convenience overload that allocates; used by the tests.
    public func denoiseWindow(
        _ mosaic: [Float],
        window: Int,
        shot: [Double],
        read: [Double]
    ) throws -> [Float] {
        var denoised = [Float](repeating: 0, count: window * window)
        try mosaic.withUnsafeBufferPointer { src in
            try denoised.withUnsafeMutableBufferPointer { dst in
                try denoiseWindow(src.baseAddress!, window: window,
                                  shot: shot, read: read, into: dst.baseAddress!)
            }
        }
        return denoised
    }

    /// Split a `2T × 2T` window into the 4 packed planes and their sigma planes.
    ///
    /// Each plane is a plain 2× downsample at a fixed (dy, dx) offset, so every
    /// row is a strided gather of T samples from a 2T-long row. Doing that with
    /// `vDSP_vgathr`-style manual indexing is already cheap; the win here is
    /// writing straight into the destination and giving the loop a contiguous
    /// out-row, which lets the compiler keep both in registers.
    private func packAndSigma(_ mosaic: UnsafePointer<Float>,
                              into planes: UnsafeMutablePointer<Float>,
                              shot: [Double], read: [Double]) {
        let T = planeSide
        let W = T * 2
        let planeSize = T * T

        for p in 0..<4 {
            let (dy, dx) = layout.offsets[p]
            let a = Float(shot[p])
            let b = Float(read[p])
            let base = p * planeSize
            let sbase = (4 + p) * planeSize

            for y in 0..<T {
                let srcRow = mosaic + (y * 2 + dy) * W + dx
                var dst = base + y * T
                var sdst = sbase + y * T
                for x in 0..<T {
                    let v = srcRow[x * 2]
                    planes[dst] = v
                    let varPart = a * v + b
                    planes[sdst] = varPart > 0 ? varPart.squareRoot() : 0
                    dst += 1
                    sdst += 1
                }
            }
        }
    }

    /// Scatter the 4 model planes back into a mosaic window.
    private func unpack(_ planes: UnsafePointer<Float>,
                        into out: UnsafeMutablePointer<Float>,
                        window W: Int) {
        let T = planeSide
        let planeSize = T * T

        for p in 0..<4 {
            let (dy, dx) = layout.offsets[p]
            let base = p * planeSize
            for y in 0..<T {
                let src = planes + base + y * T
                let dstRow = out + (y * 2 + dy) * W + dx
                for x in 0..<T {
                    dstRow[x * 2] = src[x]
                }
            }
        }
    }
}
