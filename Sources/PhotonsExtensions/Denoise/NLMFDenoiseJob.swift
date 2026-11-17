//
//  NLMFDenoiseJob.swift
//
//  Photons' second AI-denoise path: the MIT-licensed nonlocal match-filter network,
//  linked **in-process**.
//
//  Why this exists next to `AnselDenoiseJob`
//  -----------------------------------------
//  Ansel's weights are GPL-3.0, so Photons drives that tool as a separate process
//  with a JSON envelope and cannot link it. This network's code and weights are
//  MIT, so there is no licence boundary to preserve: the call is a plain throwing
//  method, the report is a struct, and there is no executable to locate. That is
//  the only architectural difference — the two jobs present the same shape to the
//  UI so a caller can swap one for the other.
//
//  The knobs below are the ones measured on a 60 MP high-ISO frame. They are not
//  defaults inherited from a library: each was chosen by comparing renders.
//

import Foundation
import NonlocalMatchFilter

public struct NLMFDenoiseJob: Sendable {

    /// Which converted network to run. The spatial size is baked into the graph,
    /// so the model file decides the tile size.
    ///
    /// Only `.t256` ships. `.t512` is real and measured, but it is 14 % slower
    /// (75 s vs 66 s on 60 MP) for a quality difference of 0.06/255 — it earns its
    /// place in the upstream repo's comparison table, not 72 MB of app bundle.
    public enum Variant: String, Sendable, CaseIterable {
        case t256 = "v_matmul_256.mlpackage"

        public var approximateBytes: Int {
            switch self {
            case .t256: return 63 * 1000 * 1000
            }
        }

        /// Plane side the graph was traced for; the mosaic window is twice this.
        public var planeSide: Int {
            switch self {
            case .t256: return 256
            }
        }
    }

    /// `$PHOTONS_NLMF_MODEL` — dev override, same convention as `PHOTONS_ANSEL_MODEL`.
    public static let environmentKey = "PHOTONS_NLMF_MODEL"

    public var variant: Variant
    /// Explicit model path; `nil` means resolve from the bundle (then the env var).
    public var modelURL: URL?

    public init(variant: Variant = .t256, modelURL: URL? = nil) {
        self.variant = variant
        self.modelURL = modelURL
    }

    // MARK: - Where the model lives

    /// The app-bundled location. A missing model therefore means **the bundle is
    /// broken**, not that the user has not downloaded anything — the same reading
    /// `AnselDenoiseJob.modelPathHint` takes, and for the same reason: pointing a
    /// user at a directory we never asked them to fill in is a dead end.
    ///
    /// SwiftPM puts `.copy(...)` resources in a per-target bundle
    /// (`Photons_PhotonsExtensions.bundle`), not in the executable, so this has to
    /// go through `Bundle.module`. Looking in `Bundle.main` finds nothing and the
    /// feature silently reports itself unavailable.
    ///
    /// `Bundle.module` is internal, so it cannot appear in a public default
    /// argument; pass `nil` (or omit) to get it.
    public static func expectedModelPath(variant: Variant,
                                         bundle: Bundle? = nil) -> URL? {
        let resolved = bundle ?? .module
        // `.copy("Denoise/Models")` flattens to Resources/Models in the target bundle.
        return resolved.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent(variant.rawValue)
    }

    /// Candidates in the order they are tried, so the tooltip and the lookup agree.
    public func searchedModelURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle? = nil
    ) -> [URL] {
        if let modelURL { return [modelURL] }
        var out: [URL] = []
        if let env = environment[Self.environmentKey], !env.isEmpty {
            out.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        if let bundled = Self.expectedModelPath(variant: variant, bundle: bundle) {
            out.append(bundled)
        }
        return out
    }

    /// First candidate that exists. `nil` means the feature is unavailable today and
    /// the menu item should be greyed out — checked before the ~90 s run, not after.
    public func resolvedModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        searchedModelURLs(environment: environment, bundle: bundle)
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    public func modelPathHint(bundle: Bundle? = nil) -> String {
        modelURL?.path
            ?? Self.expectedModelPath(variant: variant, bundle: bundle)?.path
            ?? "(bundle resources unavailable)"
    }

    // MARK: - Options

    /// The settings that were measured to look right on a high-ISO 60 MP frame.
    ///
    /// - `checkerboardNoise`: half the blocks during noise estimation, alternating
    ///   on a checkerboard. Saves ~4 s of an ~90 s run and moves the shot-noise
    ///   coefficient `a` by 3.6 %. Unlike a coarser stride it thins every brightness
    ///   level evenly, which is what the fit needs — a stride subsample drops the
    ///   dark end first, and that is the end that pins the curve.
    /// - `crop: 4`: discard the unreliable border of each tile, in **plane** pixels
    ///   (8 mosaic pixels). A tile's edge is a seam, and two differently-anchored
    ///   grids disagree there at 9× the interior rate at 0–1 px. 4 removes most of
    ///   the visible artefact at `strength 0.7`.
    /// - `strength: 0.70`: at 1.0 the network plastifies fine texture on metal and
    ///   foliage. 0.7 measured best; 0.5 starts letting noise back through.
    public func options(modelURL: URL) -> NLMFDenoiseOptions {
        var o = NLMFDenoiseOptions(modelURL: modelURL)
        o.strength = 0.70
        o.crop = 4
        o.measureNoise = true
        o.checkerboardNoise = true
        return o
    }

    // MARK: - Running

    /// `true` when the model is present, so the caller can grey out the entry point
    /// instead of failing after the user commits to a minute of work.
    public func isAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle? = nil
    ) -> Bool {
        resolvedModel(environment: environment, bundle: bundle) != nil
    }

    /// Denoise `input` into `output`.
    ///
    /// Blocks for ~90 s on a 60 MP frame, almost all of it GPU inference. Call it
    /// off the main actor; `progress` is delivered synchronously from that thread.
    public func denoise(
        input: URL,
        output: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> NLMFDenoiseReport {
        guard let model = resolvedModel() else {
            throw NLMFDenoiseJobError.modelMissing(expected: modelPathHint())
        }
        let service = NLMFDenoiseService()
        return try service.denoise(input: input,
                                   output: output,
                                   options: options(modelURL: model),
                                   progress: progress)
    }
}

public enum NLMFDenoiseJobError: Error, CustomStringConvertible, Sendable {
    /// The model is not where the bundle says it should be — a packaging fault, not
    /// a user error, so the message names the path it looked at.
    case modelMissing(expected: String)

    public var description: String {
        switch self {
        case .modelMissing(let path):
            return "非局部匹配滤波降噪模型没有随应用打包（缺少 \(path)）"
        }
    }
}
