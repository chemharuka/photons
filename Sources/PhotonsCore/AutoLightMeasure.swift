import Foundation
import Metal

// MARK: - 422 — the one bridge from 自动调节 to the pipeline
//
// The algorithm in `AutoLight` is pure: it asks for a document's **grid of luma** and decides from it.
// This is that ask, and it is deliberately the pipeline's own measurement rather than a second
// arithmetic:
//
//   · the pixels are the **pre-S4 scene-linear** texture S3 wrote (`RenderOptions.collectHistogram`'s
//     own source), so the numbers describe the photograph and not a panel;
//   · the grid is the stride sample `histogram_sample_linear` already produces (070), so no new kernel
//     and no new readback path exists;
//   · the canvas is the **whole picture** at a ≤512-long-edge scale, so a percentile means the picture
//     and not the camera.
//
// What it deliberately does **not** do: cache. `measureHistogram` explains why (`useCache: false` —
// the stage cache is keyed by canvas, so a thumbnail render's entries could only evict the frame's
// own). A 自动调节 run is a handful of renders at 0.17 Mpx; at that size a cold walk is cheaper than
// the cache thrash it would cause.

extension RenderGraph {

    /// Render `edit` at the algorithm's measurement scale and hand back the luma grid.
    ///
    /// Cost, measured on L1030433 at 0.25 rung: ~8–14 ms warm for the render plus the 512-grid
    /// readback, which is why `AutoLight.sampleLongEdge` is 512 and not 1024 — the first difference the
    /// texture criterion takes would read sampling noise rather than contrast if the grid were coarser.
    public func measureAutoLightSample(_ edit: EditModel, longEdge: Int = AutoLight.sampleLongEdge)
        throws -> AutoLight.Sample {
        let pixels = edit.geometry.outputPixels(in: sourceSize)
        let long = Double(max(pixels.width, pixels.height))
        let cap = max(64, longEdge)
        let scale = long > Double(cap) ? Double(cap) / long : 1
        let options = RenderOptions(
            scale: scale,
            // `headroom: 1` on purpose: this render is never presented, and a panel's headroom would
            // only change what S4 writes *after* the texture we read. The ceiling is the user's
            // (`HighlightCeiling.current`) because it is part of the picture — S2 clamps at it, and a
            // measurement that ignored it would see light the render cannot produce.
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1,
                                    sdrProof: false, highlightCeiling: HighlightCeiling.current),
            useCache: false, wantsPixels: false,
            collectHistogram: false, histogramSampleLongEdge: cap)
        let result = try render(edit, options: options)
        if let texture = result.output { recycle(output: texture) }
        guard let sample = result.histogramSample else {
            throw RenderError.executeFailed("auto light: no scene-linear sample")
        }
        return AutoLight.Sample(sample)
    }
}
