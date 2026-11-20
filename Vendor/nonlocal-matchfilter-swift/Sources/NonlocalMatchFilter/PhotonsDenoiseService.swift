//
//  PhotonsDenoiseService.swift
//
//  A thin host-facing layer shaped like `AnselDenoiseService` in Photons, so the
//  app can swap one denoiser for the other without changing its call sites.
//
//  The difference from Ansel matters architecturally: Ansel's weights are GPL-3.0,
//  so Photons drives it as a **separate process** with a JSON envelope. This
//  network is MIT, so it links in and the call is a plain throwing method. The
//  service therefore mirrors the *shape* of that API without the subprocess: same
//  option fields, same report fields, no executable to locate.
//

import Foundation

public struct NLMFDenoiseOptions: Sendable, Equatable {
    /// Path to the converted Core ML model. The spatial size in the graph decides
    /// the tile size; a 256 model consumes 512² mosaic pixels per call.
    public var modelURL: URL
    /// How much of the denoised result to keep: `out = in + s·(denoised − in)`.
    ///
    /// `nil` (default) derives it from the measured curve — see `NLMFStrength`.
    /// One value cannot suit every ISO: at 1.0 the network smooths fine texture on
    /// metal and foliage into a plastic surface, while a value low enough to keep
    /// that texture leaves a high-ISO frame's grain half-removed, and half-removed
    /// grain reads as detail. Set it explicitly only to override that.
    public var strength: Double?
    /// Border to discard from each tile, in plane pixels (8 mosaic pixels).
    ///
    /// The network's tile edges are seams — it conditioned its answer on a
    /// boundary that is not in the picture — and two differently-anchored grids
    /// disagree there by 9× the interior rate at 0–1 px. 4 removes most of the
    /// visible artefact; only interior seams are cropped, never the frame's own
    /// edge.
    public var crop: Int = 4
    /// Measure the Poisson-Gaussian curve from this frame (~8 s) instead of using
    /// `noiseA`/`noiseB`. Recommended: the shipped defaults assume a moderate-ISO
    /// full-frame sensor and understate a high-ISO file's midtone σ by ~1.8×.
    public var measureNoise: Bool = true
    /// Half the blocks during measurement, on a checkerboard. Saves ~4 s and
    /// moves `a` by ~3.6 %, because unlike a coarser stride it thins every
    /// brightness level evenly.
    public var checkerboardNoise: Bool = false
    /// Per-plane `Var = a·x + b` coefficients, used only when `measureNoise` is
    /// false. Order is R, G, B, G.
    public var noiseA: [Double] = []
    public var noiseB: [Double] = []

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }
}

public struct NLMFDenoiseReport: Sendable, Equatable {
    public let output: URL
    public let width: Int
    public let height: Int
    public let cfa: String
    public let tiles: Int
    /// Strength actually applied (the option, or the value derived from σ).
    public let strength: Double
    /// Green-plane σ at 5 % brightness behind that choice.
    public let sigma: Double
    public let seconds: Double
    public let inferenceSeconds: Double
    public let outputBytes: Int
}

public struct NLMFDenoiseFailure: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Denoise a DNG with the nonlocal match-filter network, in-process.
public struct NLMFDenoiseService: Sendable {

    public init() {}

    /// Whether the model can be loaded at all, so a menu item can be greyed out
    /// instead of failing after the user clicks it.
    public func isAvailable(modelURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Denoise `input` into `output`. Both must be DNG; the output's parent
    /// directory must exist.
    ///
    /// - Note: this blocks for roughly 90 s on a 60 MP frame. Call it off the main
    ///   actor; `progress` is delivered synchronously from the calling thread.
    public func denoise(input: URL,
                        output: URL,
                        options: NLMFDenoiseOptions,
                        progress: (@Sendable (String) -> Void)? = nil) throws -> NLMFDenoiseReport {
        guard input.pathExtension.lowercased() == "dng",
              output.pathExtension.lowercased() == "dng" else {
            throw NLMFDenoiseFailure(code: "bad_input",
                                     message: "input and output must both be .dng")
        }
        guard isAvailable(modelURL: options.modelURL) else {
            throw NLMFDenoiseFailure(code: "model_missing",
                                     message: "no Core ML model at \(options.modelURL.path)")
        }
        if !options.measureNoise && options.noiseA.count != 4 {
            throw NLMFDenoiseFailure(
                code: "bad_noise",
                message: "noiseA/noiseB need 4 per-plane values (R, G, B, G) "
                       + "when measureNoise is false")
        }

        let request = DenoiseRequest(
            input: input,
            output: output,
            mlpackage: options.modelURL.path,
            a: options.noiseA,
            b: options.noiseB,
            strength: options.strength,
            crop: options.crop,
            estimateNoise: options.measureNoise,
            checkerboardNoise: options.checkerboardNoise)

        do {
            let report = try DenoisePipeline.run(request) { line in progress?(line) }
            return NLMFDenoiseReport(
                output: output,
                width: report.width,
                height: report.height,
                cfa: report.cfa,
                tiles: report.tiles,
                strength: report.strength,
                sigma: report.sigma,
                seconds: report.seconds,
                inferenceSeconds: report.inferenceSeconds,
                outputBytes: report.outputBytes)
        } catch let e as PipelineError {
            throw NLMFDenoiseFailure(code: "pipeline", message: e.description)
        } catch let e as CoreMLError {
            throw NLMFDenoiseFailure(code: "coreml", message: e.description)
        }
    }
}
