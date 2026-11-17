#if os(iOS)
import PhotonsLocalization
import SwiftUI
import UIKit
import PhotonsCore

/// Same code/tail split and linear, endpoint-resistant peak rule as the Mac HistogramPlot.
enum MobileHistogramReading {
    static func bin(at fraction: Double) -> (tail: Bool,index: Int) {
        let u = min(1,max(0,fraction.isFinite ? fraction : 0))
        if u >= 0.5 { return (true,min(255,Int((u-0.5)*512))) }
        return (false,min(255,Int(u*512)))
    }
    static func peak(_ channel: HistogramChannel) -> Int {
        let values = channel.bins + channel.hdrBins
        let interior = values.dropFirst().dropLast().max() ?? 0
        return max(1,interior > 0 ? interior : (values.max() ?? 0))
    }
    static func points(_ channel: HistogramChannel,size: CGSize) -> [CGPoint] {
        let counts = channel.bins + channel.hdrBins, scale = Double(peak(channel))
        return [CGPoint(x: 0,y: size.height)] + counts.enumerated().map { i,count in
            CGPoint(x: (Double(i)+0.5)/Double(max(1,counts.count))*size.width,
                    y: size.height*(1-min(1,Double(count)/scale)))
        } + [CGPoint(x: size.width,y: size.height)]
    }
    /// Maximum envelope coverage over a whole display pixel, preserving narrow peaks.
    /// Adapted from the current Mac HistogramCardView.envelopeMax (upstream 737f92d).
    static func top(_ points: [CGPoint],from: CGFloat,to: CGFloat,cursor: inout Int) -> CGFloat {
        guard points.count >= 2,let first = points.first,let last = points.last else { return .nan }
        if to <= first.x { return first.y }
        if from >= last.x { return last.y }
        let lo = max(from,first.x), hi = min(to,last.x)
        var i = min(max(cursor,0),points.count-2)
        while i > 0 && points[i].x > lo { i -= 1 }
        while i < points.count-2 && points[i+1].x < lo { i += 1 }
        func sample(_ index: Int,_ x: CGFloat) -> CGFloat {
            let a = points[index], b = points[index+1], dx = b.x-a.x
            guard dx > 0 else { return b.y }
            return a.y+(b.y-a.y)*min(1,max(0,(x-a.x)/dx))
        }
        var best = sample(i,lo), k = i
        while k < points.count-1 && points[k+1].x <= hi { k += 1; best = min(best,points[k].y) }
        best = min(best,k == points.count-1 ? points[k].y : sample(k,hi))
        cursor = k
        return best
    }
    static func bands(tops: [CGFloat],bottom: CGFloat) -> [(top: CGFloat,height: CGFloat,mask: Int)] {
        let present = tops.enumerated().filter { $0.element.isFinite && $0.element < bottom-1e-9 }
            .sorted { $0.element > $1.element }
        var mask = present.reduce(0) { $0 | (1 << $1.offset) }, upper = bottom
        var result: [(top: CGFloat,height: CGFloat,mask: Int)] = []
        for entry in present {
            result.append((entry.element,upper-entry.element,mask))
            upper = entry.element; mask &= ~(1 << entry.offset)
        }
        return result
    }
    static func percent(_ value: Double) -> String {
        if value > 0 && value < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%",value*100)
    }
}
struct MobileHistogram: View {
    let histogram: Histogram
    var hdr = true
    @Environment(\.displayScale) private var displayScale
    @State private var headroom = 1.0
    @State private var pointer: Double?
    private var measured: Histogram { histogram.withDisplayHeadroom(hdr ? headroom : 1) }
    var body: some View {
        VStack(alignment: .leading,spacing: 7) {
            HStack {
                Text(hdr ? "HDR · Rec.2020" : "SDR · Display P3").font(.caption.weight(.semibold))
                Spacer()
                Text("\(histogram.canvas.width) × \(histogram.canvas.height)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Canvas { context,size in
                    let split = size.width/2
                    context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(.black))
                    context.fill(Path(CGRect(x: split,y: 0,width: split,height: size.height)),with: .color(Color(white: 0.07)))
                    let envelopes = [histogram.red,histogram.green,histogram.blue].map {
                        MobileHistogramReading.points($0,size: size)
                    }
                    let strip = 1 / max(1,displayScale)
                    var cursors = [0,0,0], paths = Array(repeating: Path(),count: 8)
                    for column in 0..<Int(ceil(size.width/strip)) {
                        let x = CGFloat(column)*strip, width = min(strip,size.width-x)
                        let tops = envelopes.enumerated().map { i,points in
                            MobileHistogramReading.top(points,from: x,to: x+width,cursor: &cursors[i])
                        }
                        for band in MobileHistogramReading.bands(tops: tops,bottom: size.height) {
                            paths[band.mask].addRect(CGRect(x: x,y: band.top,width: width,height: band.height))
                        }
                    }
                    // Construct bounded sRGB additive colors before display-space conversion.
                    // Never add encoded P3/EDR components with plusLighter (Mac fixes 406c/413).
                    for mask in 1...7 {
                        let color = Color(.sRGB,red: mask & 1 == 0 ? 0 : 1,
                                          green: mask & 2 == 0 ? 0 : 1,blue: mask & 4 == 0 ? 0 : 1,opacity: 1)
                        context.fill(paths[mask],with: .color(color))
                    }
                    for i in 1...4 {
                        var line = Path(); let x = split*Double(i)/4
                        line.move(to: CGPoint(x: x,y: 0)); line.addLine(to: CGPoint(x: x,y: size.height))
                        line.move(to: CGPoint(x: split+x,y: 0)); line.addLine(to: CGPoint(x: split+x,y: size.height))
                        context.stroke(line,with: .color(.white.opacity(0.2)),lineWidth: 0.5)
                    }
                    do {
                        let x = split + split * min(4,max(0,log2(max(1,hdr ? headroom : 1))))/4
                        var ceiling = Path(); ceiling.move(to: CGPoint(x: x,y: 0)); ceiling.addLine(to: CGPoint(x: x,y: size.height))
                        context.stroke(ceiling,with: .color(.orange),style: StrokeStyle(lineWidth: 1,dash: [3,3]))
                    }
                    if let pointer {
                        var cursor = Path(); let x = pointer*size.width
                        cursor.move(to: CGPoint(x: x,y: 0)); cursor.addLine(to: CGPoint(x: x,y: size.height))
                        context.stroke(cursor,with: .color(.white),lineWidth: 1)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { pointer = min(1,max(0,$0.location.x/max(1,geometry.size.width))) })
            }.frame(height: 88).accessibilityIdentifier("histogram-plot")
            HStack(spacing: 0) {
                HStack { Text("0"); Spacer(); Text("128"); Spacer(); Text("255") }
                HStack { Spacer(); Text("+1"); Spacer(); Text("+2"); Spacer(); Text("+3"); Spacer(); Text("+4") }
            }.font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                metric(L10n.tr("ipad.f513cadb12e6"),measured.luma.clippedHigh)
                Spacer(minLength: 3); metric(L10n.tr("ipad.3494bc107f0b"),measured.luma.clippedCeiling)
                Spacer(minLength: 3); metric(L10n.tr("ipad.c7fb958ca041"),measured.luma.clippedLow)
            }.accessibilityIdentifier("histogram-clipping")
            if let pointer {
                let reading = MobileHistogramReading.bin(at: pointer)
                HStack(spacing: 6) {
                    Text(reading.tail ? String(format: L10n.tr("ipad.194dbe6365ff"),Double(reading.index)/64) : L10n.tr("ipad.e58137125ffd", String(describing: (reading.index))))
                    ForEach(Array([histogram.red,histogram.green,histogram.blue].enumerated()),id: \.offset) { i,channel in
                        let bins = reading.tail ? channel.hdrBins : channel.bins
                        Text("\(["R","G","B"][i]) \(bins.indices.contains(reading.index) ? bins[reading.index] : 0)")
                            .foregroundStyle([Color.red,.green,.blue][i])
                    }
                }.font(.system(size: 10).monospacedDigit()).accessibilityIdentifier("histogram-readout")
            } else { Text(L10n.tr("ipad.c3f0710b2a57")).font(.caption2).foregroundStyle(.secondary) }
            HStack {
                Text(L10n.tr("ipad.ad4d56d9f46a", String(describing: (histogram.sampleCount))))
                Spacer()
                Text(String(format: L10n.tr("ipad.2d872cd6dc23"),log2(max(1,hdr ? headroom : 1))))
            }.font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("ipad.6b98e8e09447"))
            .onAppear { updateHeadroom() }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in updateHeadroom() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in updateHeadroom() }
            .onChange(of: hdr) { _,_ in updateHeadroom() }
    }
    private func updateHeadroom() { headroom = min(16,max(1,Double(UIScreen.main.currentEDRHeadroom))) }
    private func metric(_ label: String,_ ratio: Double) -> some View {
        VStack(alignment: .leading,spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(MobileHistogramReading.percent(ratio)).font(.caption2.monospacedDigit())
        }.accessibilityElement(children: .combine)
    }
}
#endif
