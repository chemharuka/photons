import Foundation
import CoreImage
import AppKit

// Probe: does Apple's RAW decoder accept a hand-built synthetic CFA DNG?
// Usage: swift tools/wb-calibrate/probe.swift <file.dng>

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: probe.swift <file.dng>"); exit(2) }
let url = URL(fileURLWithPath: args[1])

guard let raw = CIRAWFilter(imageURL: url) else {
    print("CIRAWFilter(imageURL:) == nil  → decoder refused the file outright")
    exit(1)
}
print("filter created          YES")
print("nativeSize              \(raw.nativeSize)")
print("decoderVersion          \(String(describing: raw.decoderVersion))")
print("supportedDecoderVersions \(raw.supportedDecoderVersions)")
print("outputImage             \(raw.outputImage != nil)  extent \(raw.outputImage?.extent ?? .zero)")

// Which body does the decoder think this is?
let keys = (raw.properties as NSDictionary).allKeys.compactMap { $0 as? String }.sorted()
print("property keys           \(keys.prefix(14).joined(separator: ", "))…")

func mean(_ img: CIImage) -> (Double, Double, Double) {
    let ctx = CIContext(options: [.workingColorSpace: NSNull()])
    let e = img.extent
    guard let cg = ctx.createCGImage(img, from: e) else { return (.nan, .nan, .nan) }
    let w = min(cg.width, 64), h = min(cg.height, 64)
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return (.nan, .nan, .nan)
    }
    c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var r = 0.0, g = 0.0, b = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        r += Double(buf[i]); g += Double(buf[i + 1]); b += Double(buf[i + 2])
    }
    let n = Double(w * h)
    return (r / n, g / n, b / n)
}

// WB response: the whole point of the exercise — does the decoder's output move with temperature?
for t in [3500.0, 5000.0, 6500.0, 9000.0] {
    raw.neutralTemperature = Float(t)
    raw.neutralTint = 0
    let img = raw.outputImage
    let m = img.map(mean) ?? (.nan, .nan, .nan)
    print(String(format: "  wb %.0f K → R %.1f  G %.1f  B %.1f   (B/R %.3f)", t, m.0, m.1, m.2, m.2 / max(m.0, 1e-6)))
}
