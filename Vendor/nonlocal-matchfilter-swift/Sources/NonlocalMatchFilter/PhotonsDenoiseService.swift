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
    /// How much of the blend weight to give up towards the highlights, and where
    /// that happens, in normalised linear RAW brightness.
    ///
    /// `strength` is one number for the whole frame; the detail the network takes
    /// away is not spread evenly, it concentrates where the signal is strong.
    /// `highlightTaper = q` scales the blend by
    /// `1 − q·smoothstep(taperLow, taperHigh, x)`: shadows keep the whole
    /// `strength` (bit for bit below `taperLow`), highlights keep
    /// `strength·(1 − q)`.
    ///
    /// The knees are *linear scene* values, not what the eye calls bright — a
    /// tone curve lifts shadows 2–4×, so 0.18 here reads as ~0.46 on screen. A
    /// dark frame can put its brightest detail below 0.18 and then nothing
    /// happens; 0.05–0.25 was measured to reach a museum interior's gold while
    /// staying above a bright outdoor frame's midtones.
    public var highlightTaper: Double = 0
    public var taperLow: Double = 0.18
    public var taperHigh: Double = 0.60
    /// Mirror of `highlightTaper` at the floor: where x is comparable to its own
    /// noise the network has nothing to separate, but flattens it anyway, and the
    /// flattening *is* the picture there. `shadowTaper = q` keeps
    /// `strength·(1 − q)` at or below `shadowLow` and the unmodified `strength`
    /// at or above `shadowHigh` (bit for bit).
    public var shadowTaper: Double = 0
    public var shadowLow: Double = 0.002
    public var shadowHigh: Double = 0.02
    /// Coherence gate on the residual's finest band (`DetailGate`), as `wMax`.
    /// 0 turns it off and restores the historical blend exactly.
    public var detailGate: Double = 0.85
    public var detailKneeLow: Double = 1.05
    public var detailKneeHigh: Double = 1.25
    public var detailSigma: Double = 1.5
    /// Coherence box **half-width** in plane pixels; the window is 2·box+1.
    public var detailBox: Int = 16
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
    /// Blend weight left at the highlight end of the taper; equal to `strength`
    /// when `highlightTaper` is 0.
    public let highlightStrength: Double
    /// Blend weight left at the floor; equal to `strength` when `shadowTaper` is 0.
    public let shadowStrength: Double
    /// Green-plane σ at 5 % brightness behind that choice.
    public let sigma: Double
    /// Mean `DetailGate` weight; 0 when the gate is off.
    public let detailMeanWeight: Double
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
            strengthTaper: options.highlightTaper,
            taperLow: options.taperLow,
            taperHigh: options.taperHigh,
            shadowTaper: options.shadowTaper,
            shadowLow: options.shadowLow,
            shadowHigh: options.shadowHigh,
            detailGate: options.detailGate,
            detailKneeLow: options.detailKneeLow,
            detailKneeHigh: options.detailKneeHigh,
            detailSigma: options.detailSigma,
            detailBox: options.detailBox,
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
                highlightStrength: report.strengthHighlight,
                shadowStrength: report.strengthShadow,
                sigma: report.sigma,
                detailMeanWeight: report.detailMeanWeight,
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
