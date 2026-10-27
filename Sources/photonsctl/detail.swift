import Foundation
import PhotonsCore

// MARK: - detail probe (派单 031)
//
// The one question this command answers, per file and per decoder version: **what do the four
// noise-reduction / detail properties actually do here?**
//
// It has to be a probe and not a test because the answer is machine- and body-specific:
//
//   · the filter's own defaults are not 0 on every axis (measured: colour NR 0.5 and sharpness 0.5
//     on a Leica SL3, sharpness 1.0 on an EOS R5), and
//   · "the value was accepted" and "the pixels moved" are two different answers — the filter reads
//     back anything it is given (2.0 stays 2.0) and then may ignore it entirely.
//
// So each row prints the value the develop assigned (`detailApplied`, read back from the filter) and
// the number of samples that differ from the untouched decode of the same file at the same scale.
//
//     photonsctl detail <raw> [--version V] [--scale F]
//
// `--scale` defaults to 0.1: every row is a fresh development, so this is a spot check of the whole
// 60 MP frame, not a full-size measurement.

func cmdDetail(_ a: Args) throws {
    let url = requireRaw(a)
    let decoder = makeDecoder()
    let version = a.value("--version")
    let scale = Float(a.value("--scale") ?? "0.1") ?? 0.1

    let offered = try RAWDecoder.availableVersions(for: url)
    note("file            \(url.lastPathComponent)")
    note("versions        \(offered.joined(separator: ", ")) · requested \(version ?? "auto")")
    note("scale           \(String(format: "%.3f", scale))")

    let untouched = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: version,
                                                                          scale: scale))
    note("decoder         v\(untouched.capabilities.effectiveVersion)")
    note("axes            \(untouched.capabilities.detailAxes.flagSummary)"
         + "  [\(untouched.capabilities.detailAxesProvenance.rawValue)]")
    let b = untouched.detailBaseline
    note("baseline        luminanceNR \(f4(b.luminanceNR)) · colorNR \(f4(b.colorNR))"
         + " · sharpness \(f4(b.sharpness)) · detail \(f4(b.detail))")
    note("default position \(DetailAxis.panelOrder.map { "\($0.rawValue) \(String(format: "%.0f", $0.defaultPosition(in: b)))" }.joined(separator: " · "))")
    note("untouched       sha256 \(untouched.image.sha256().prefix(16)) "
         + "\(untouched.image.width)x\(untouched.image.height) · assigned \(untouched.detailApplied.summary)")

    print("")
    print("  axis        slider   assigned (read back)        samples vs untouched")
    print("  " + String(repeating: "-", count: 74))

    let axes: [(String, DetailAxis)] = DetailAxis.panelOrder.map { ($0.rawValue, $0) }
    // 派单 040: the sliders are positions, and 042 split the travel per axis — 细节 0…30
    // (amount 0…3), the other three 0…100 (amount 0…1). So each axis walks its *own* four
    // interesting positions: the two ends and the two middles, from its own range.
    func sliders(for axis: DetailAxis) -> [Double] {
        let hi = axis.range.upperBound
        return [0, (hi * 0.3).rounded(), (hi / 2).rounded(), hi]
    }

    for (name, axis) in axes {
        let defaultPosition = axis.defaultPosition(in: b)
        for slider in sliders(for: axis) {
            var settings = DetailSettings()
            settings[axis] = slider
            let outcome = try decoder.decodeDetailed(url,
                                                     options: DecodeOptions(decoderVersion: version,
                                                                           scale: scale,
                                                                           detail: settings))
            let applied = outcome.detailApplied
            let value = (axis == .luminanceNR ? applied.luminanceNR
                         : axis == .colorNR ? applied.colorNR
                         : axis == .sharpness ? applied.sharpness : applied.detail).map(f4)
                ?? "— (not assigned)"
            let diff = differingSamples(untouched.image.rgba, outcome.image.rgba)
            let mark = slider == defaultPosition ? "  ← default position" : ""
            print("  \(pad(name, 11)) \(padF(slider))    \(pad(value, 24))  \(diff)\(mark)")
        }
        print("")
    }

    // The clamp, demonstrated: the filter keeps what it is given, so the range is ours.
    let extremes = try decoder.decodeDetailed(url, options: DecodeOptions(
        decoderVersion: version, scale: scale,
        detail: DetailSettings(luminanceNR: 1_000, colorNR: 1_000,
                               sharpness: 1_000, detail: 1_000)))
    note("out-of-travel   slider 1000 → assigned \(extremes.detailApplied.summary)"
         + "  (0…3 for detail, 0…1 for the rest — the clamp is ours, not Apple's)")
}

private func f4(_ v: Double) -> String { String(format: "%.4f", v) }

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

private func padF(_ v: Double) -> String {
    let s = String(format: "%.0f", v)
    return s.count >= 5 ? s : String(repeating: " ", count: 5 - s.count) + s
}

private func differingSamples(_ a: [Float16], _ b: [Float16]) -> Int {
    guard a.count == b.count else { return max(a.count, b.count) }
    var n = 0
    for i in 0..<a.count where a[i] != b[i] { n += 1 }
    return n
}
