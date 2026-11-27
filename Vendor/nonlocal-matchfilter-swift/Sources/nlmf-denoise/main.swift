//
//  main.swift — nlmf-denoise
//
//  RawNIND raw->raw denoising on Core ML, DNG in and DNG out.
//
//  usage: nlmf-denoise <model.mlpackage> <in.dng> --out <out.dng>
//                      [--a r,g,b,g2] [--b r,g,b,g2] [--strength S] [--crop N]
//                      [--detail-gate 0.35] [--detail-knee 1.00,1.40]
//                      [--detail-sigma 1.5] [--detail-box 16]
//                      [--dump-gate <prefix>] [--dual-raw] [--json]
//

import Foundation
import NonlocalMatchFilter

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    die("usage: nlmf-denoise <model.mlpackage> <in.dng> --out <out.dng> "
        + "[--a r,g,b,g2] [--b r,g,b,g2] [--strength S] [--crop N] "
        + "[--detail-gate W] [--detail-knee lo,hi] [--detail-sigma PX] "
        + "[--detail-box PX] [--dump-gate PREFIX] [--dual-raw] [--json]")
}

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseDoubles(_ s: String) -> [Double] {
    s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
}

let mlpackage = args[0]
let inputPath = args[1]

// `--dump-mosaic <path>`: write the mosaic the network would be fed and stop.
// Used to compare two files in the data domain, where a render cannot look.
if let dumpPath = flag("--dump-mosaic") {
    do {
        let dump = try DenoisePipeline.dumpNormalisedMosaic(
            URL(fileURLWithPath: inputPath), to: URL(fileURLWithPath: dumpPath))
        print("dumped \(dump.width)×\(dump.height) \(dump.cfa) "
              + "black=\(dump.black.map { String(format: "%.0f", $0) }) white=\(Int(dump.white))")
        exit(0)
    } catch {
        die("error: \(error)")
    }
}

guard let outPath = flag("--out") else { die("missing --out") }

// Defaults are the ones the reference tool ships for a full-frame sensor; the
// pairs are per CFA channel in the model's R, G, B, G order.
let a = flag("--a").map(parseDoubles) ?? [0.0004, 0.0003, 0.0004, 0.0003]
let b = flag("--b").map(parseDoubles) ?? [3e-6, 1e-6, 1e-6, 1e-6]
guard a.count == 4, b.count == 4 else { die("--a and --b each need 4 values (R,G,B,G)") }

// No `--strength` means "derive it from this frame's noise" (NLMFStrength).
let strength = flag("--strength").flatMap(Double.init)
// `--strength-taper q` gives up `q` of the blend weight towards the highlights
// (shadows keep the whole `strength`); 0, the default, is the old behaviour.
let strengthTaper = flag("--strength-taper").flatMap(Double.init) ?? 0
// `--taper-knee lo,hi` moves where the taper starts and finishes (linear RAW
// brightness). Defaults match the mid-grey anchored mapping.
let knee = flag("--taper-knee").map(parseDoubles) ?? []
let taperLow = knee.count == 2 ? knee[0] : 0.18
let taperHigh = knee.count == 2 ? knee[1] : 0.60
// `--shadow-taper q --shadow-knee lo,hi`: the mirror at the bottom of the range.
let shadowTaper = flag("--shadow-taper").flatMap(Double.init) ?? 0
let sknee = flag("--shadow-knee").map(parseDoubles) ?? []
let shadowLow = sknee.count == 2 ? sknee[0] : 0.002
let shadowHigh = sknee.count == 2 ? sknee[1] : 0.02
// `--detail-gate w` caps how much of the residual's finest band the network may
// remove. 0 is the rollback switch and reproduces the old blend bit for bit.
let detailGate = flag("--detail-gate").flatMap(Double.init) ?? 0.35
let dknee = flag("--detail-knee").map(parseDoubles) ?? []
let detailKneeLow = dknee.count == 2 ? dknee[0] : 1.00
let detailKneeHigh = dknee.count == 2 ? dknee[1] : 1.40
// Gaussian sigma in plane pixels; 1.5 plane px = 3 mosaic px.
let detailSigma = flag("--detail-sigma").flatMap(Double.init) ?? 1.5
// Coherence box half-width in plane pixels; the window is 2·box+1.
let detailBox = flag("--detail-box").flatMap(Int.init) ?? 16
// `--dump-gate <prefix>`: write the per-pixel weight as <prefix>.f32 with a
// `width height` sidecar, for the patch metric (std of block means).
let detailGateDump = flag("--dump-gate").map { URL(fileURLWithPath: $0) }
let crop = flag("--crop").flatMap(Int.init) ?? 0
// `--measure-noise` estimates the sensor's Poisson-Gaussian curve from this
// frame and ignores --a/--b. Without it, or with explicit values, the CLI
// defaults below are used.
let measureNoise = args.contains("--measure-noise")
// With --measure-noise, --noise-sample=checkerboard halves the blocks it reads.
let checkerboardNoise = flag("--noise-sample").map { $0 == "checkerboard" } ?? false
/// Keep both mosaics in the output: the original as IFD0 and the denoised result
/// as the alternate behind `330 SubIFDs`. Readers that do not know about the
/// alternate see the original, unchanged.
let dualRaw = args.contains("--dual-raw")
let asJSON = args.contains("--json")

let request = DenoiseRequest(
    input: URL(fileURLWithPath: inputPath),
    output: URL(fileURLWithPath: outPath),
    mlpackage: mlpackage,
    a: a, b: b, strength: strength, strengthTaper: strengthTaper,
    taperLow: taperLow, taperHigh: taperHigh,
    shadowTaper: shadowTaper, shadowLow: shadowLow, shadowHigh: shadowHigh,
    detailGate: detailGate, detailKneeLow: detailKneeLow,
    detailKneeHigh: detailKneeHigh, detailSigma: detailSigma,
    detailBox: detailBox, detailGateDump: detailGateDump,
    crop: crop,
    estimateNoise: measureNoise, checkerboardNoise: checkerboardNoise,
    dualRaw: dualRaw)

do {
    let report = try DenoisePipeline.run(request) { line in
        if !asJSON { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }
    if asJSON {
        var obj: [String: Any] = [
            "width": report.width,
            "height": report.height,
            "cfa": report.cfa,
            "blackMean": report.blackMean,
            "white": report.white,
            "tiles": report.tiles,
            "tilesX": report.tilesX,
            "tilesY": report.tilesY,
            "readSeconds": report.readSeconds,
            "inferenceSeconds": report.inferenceSeconds,
            "writeSeconds": report.writeSeconds,
            "seconds": report.seconds,
            "outputBytes": report.outputBytes,
            "strengthTaper": request.strengthTaper,
            "detailGate": request.detailGate,
            "detailKnee": [request.detailKneeLow, request.detailKneeHigh],
            "detailSigma": request.detailSigma,
            "detailBox": request.detailBox,
            "detailMeanWeight": report.detailMeanWeight,
            "writerTiles": report.writerTiles,
            "hasAlternate": report.hasAlternate,
        ]
        if report.hasAlternate {
            obj["alternate"] = "denoised"
            obj["alternateBytes"] = report.alternateBytes
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        print("wrote \(outPath)  \(report.width)×\(report.height) \(report.cfa)")
        print(String(format: "  strength %.3f (σ(0.05)=%.5f)  highlights %.3f  read %.1f s, inference %.1f s, write %.1f s, total %.1f s",
                     report.strength, report.sigma, report.strengthHighlight,
                     report.readSeconds, report.inferenceSeconds,
                     report.writeSeconds, report.seconds))
        if request.detailGate > 0 {
            print(String(format: "  detail gate %.2f (knee %.2f–%.2f, σf %.2f px, box ±%d px), mean weight %.3f",
                         request.detailGate, request.detailKneeLow,
                         request.detailKneeHigh, request.detailSigma,
                         request.detailBox, report.detailMeanWeight))
        }
        print("  \(report.tiles) tiles (\(report.tilesX)×\(report.tilesY)), "
              + "\(report.outputBytes / 1_000_000) MB")
    }
} catch {
    die("error: \(error)")
}
