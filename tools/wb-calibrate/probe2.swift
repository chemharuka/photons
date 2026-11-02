import Foundation
import CoreImage
import AppKit

// Sample the decoded frame in a grid so we can prove the synthetic pattern survived the decode.
// Usage: swift tools/wb-calibrate/probe2.swift <file.dng> [temperature] [out.png]
// Writes the whole decoded frame to out.png (default: decoded-chart.png in the current directory).
let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: swift probe2.swift <file.dng> [temperature] [out.png]"); exit(2)
}
let url = URL(fileURLWithPath: args[1])
let temp = args.count > 2 ? Float(args[2])! : 6500
let outPath = args.count > 3 ? args[3] : "decoded-chart.png"

guard let raw = CIRAWFilter(imageURL: url), let img0 = raw.outputImage else {
    print("decoder refused"); exit(1)
}
raw.neutralTemperature = temp
raw.neutralTint = 0
guard let img = raw.outputImage else { print("no output"); exit(1) }

let ctx = CIContext(options: [.workingColorSpace: NSNull()])
let e = img.extent
let w = Int(e.width), h = Int(e.height)
guard let cg = ctx.createCGImage(img, from: e) else { print("no cgimage"); exit(1) }

var buf = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
buf.withUnsafeMutableBytes { p in
    let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}

func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
}
// CoreGraphics draws with y = 0 at the bottom; our pattern has the ramp at the top of the file.
print("frame \(w)×\(h), WB \(Int(temp)) K")
print("grey ramp (18 steps, sampled at the patch centres):")
var row: [String] = []
for i in 0..<18 {
    let x = min(w - 1, (i * w / 18) + (w / 36))
    let y = h - (h / 8)               // a little below the top edge
    let (r, g, b) = px(x, y)
    row.append(String(format: "%d", (r + g + b) / 3))
}
print("  " + row.joined(separator: " "))

print("colour patches (4×6 grid, R/G/B at each centre):")
let rampH = h / 4, bottom = h - h / 8
let bandH = (h - rampH - h / 8) / 4
for cy in 0..<4 {
    var line = "  "
    for cx in 0..<6 {
        let x = min(w - 1, cx * (w / 6) + w / 12)
        let yFile = rampH + cy * bandH + bandH / 2     // y measured from the top in file space
        let y = h - 1 - yFile
        let (r, g, b) = px(x, y)
        line += String(format: "%3d/%3d/%3d  ", r, g, b)
    }
    print(line)
}

// dump the decoded frame for statistical checking
let rep = NSBitmapImageRep(cgImage: cg)
if let png = rep.representation(using: .png, properties: [:]) {
    do {
        try png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)")
    } catch {
        print("could not write \(outPath): \(error)"); exit(1)
    }
}
