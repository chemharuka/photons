import Foundation
import CoreGraphics

/// Translation-only registration: corner descriptors, a robust displacement vote, then subpixel
/// normalized correlation. No rotation, scale or perspective degrees of freedom exist here.
enum TranslationRegistration {
    struct Match { var offset: CGPoint; var score: Double; var inliers: Int; var anchors: [CGPoint] = [] }
    private struct Corner { let x: Int; let y: Int; let strength: Double; let descriptor: [Double] }

    private static func corners(_ image: GrayRaster) -> [Corner] {
        let w = image.width, h = image.height
        guard w > 24, h > 24 else { return [] }
        var candidates: [(Int, Int, Double)] = []
        for y in stride(from: 10, to: h-10, by: 2) {
            for x in stride(from: 10, to: w-10, by: 2) {
                var xx = 0.0, yy = 0.0, xy = 0.0
                for dy in -1...1 { for dx in -1...1 {
                    let p = (y+dy)*w+x+dx
                    let gx = image.values[p+1] - image.values[p-1]
                    let gy = image.values[p+w] - image.values[p-w]
                    xx += gx*gx; yy += gy*gy; xy += gx*gy
                }}
                let score = (xx+yy-sqrt((xx-yy)*(xx-yy)+4*xy*xy)) * 0.5
                if score > 0.00008 { candidates.append((x,y,score)) }
            }
        }
        candidates.sort { $0.2 > $1.2 }
        var blocked = [Bool](repeating: false, count: w*h), result: [Corner] = []
        for (x,y,strength) in candidates where !blocked[y*w+x] {
            var descriptor: [Double] = []
            for dy in stride(from: -8, through: 8, by: 2) { for dx in stride(from: -8, through: 8, by: 2) {
                descriptor.append(image.values[(y+dy)*w+x+dx])
            }}
            let mean = descriptor.reduce(0,+) / Double(descriptor.count)
            let norm = sqrt(descriptor.reduce(0) { $0+($1-mean)*($1-mean) })
            if norm < 0.015 { continue }
            descriptor = descriptor.map { ($0-mean)/norm }
            result.append(Corner(x:x,y:y,strength:strength,descriptor:descriptor))
            for yy in max(0,y-8)...min(h-1,y+8) { for xx in max(0,x-8)...min(w-1,x+8) { blocked[yy*w+xx] = true }}
            if result.count >= 900 { break }
        }
        return result
    }

    static func correspondences(_ a:GrayRaster,_ b:GrayRaster,cancellation:PanoramaCancellation) throws -> [ProjectiveRegistration.Pair] {
        let ac = corners(a), bc = corners(b)
        var pairs: [ProjectiveRegistration.Pair] = []
        for (idx, point) in ac.enumerated() {
            if idx % 50 == 0 { try cancellation.check() }
            var best = 10.0, next = 10.0, winner: Corner?
            for other in bc {
                var distance = 0.0
                for k in point.descriptor.indices {
                    let d = point.descriptor[k]-other.descriptor[k]; distance += d*d
                }
                if distance < best { next = best; best = distance; winner = other }
                else if distance < next { next = distance }
            }
            if best < 0.5, best < next * 0.78, let winner {
                pairs.append(.init(a:CGPoint(x:point.x,y:point.y),b:CGPoint(x:winner.x,y:winner.y)))
            }
        }
        return pairs
    }

    static func align(_ a: GrayRaster, _ b: GrayRaster, cancellation: PanoramaCancellation) throws -> Match? {
        let pairs = try correspondences(a,b,cancellation:cancellation)
        let offsets = pairs.map { (offset:CGPoint(x:$0.a.x-$0.b.x,y:$0.a.y-$0.b.y),anchor:$0.a) }
        var cluster: [(offset: CGPoint, anchor: CGPoint)] = []
        for seed in offsets {
            let near = offsets.filter { hypot($0.offset.x-seed.offset.x,$0.offset.y-seed.offset.y) < 4 }
            if near.count > cluster.count { cluster = near }
        }
        guard cluster.count >= 5 else { return nil }
        let initial = CGPoint(x:median(cluster.map { Double($0.offset.x) }), y:median(cluster.map { Double($0.offset.y) }))
        let anchors = stride(from: 0, to: cluster.count, by: max(1, cluster.count / 64)).map { cluster[$0].anchor }
        let refined = refine(a,b,offset:initial,radius:3,anchors:anchors)
        guard refined.score > 0.72 else { return nil }
        return Match(offset:refined.offset,score:refined.score,inliers:cluster.count,anchors:anchors)
    }

    /// Bounded image search around measured shift differences. A measurement supplies a
    /// search window, never a successful match by itself. The final coordinates remain
    /// subpixel image matches, including when the entered reading is slightly imprecise.
    static func align(_ a:GrayRaster,_ b:GrayRaster,near expected:CGPoint,radius:Double,
                      cancellation:PanoramaCancellation) throws -> Match? {
        guard expected.x.isFinite,expected.y.isFinite,radius.isFinite,radius>0 else {return nil}
        let scale=min(1,256/Double(a.width))
        func small(_ image:GrayRaster)->GrayRaster {
            let w=max(2,Int(Double(image.width)*scale)),h=max(2,Int(Double(image.height)*scale))
            var values=[Double]();values.reserveCapacity(w*h)
            for y in 0..<h {for x in 0..<w {values.append(image.sample(Double(x)/scale,Double(y)/scale))}}
            return GrayRaster(width:w,height:h,values:values)
        }
        try cancellation.check()
        let low=refine(small(a),small(b),offset:CGPoint(x:expected.x*scale,y:expected.y*scale),radius:min(24,max(2,Int(ceil(radius*scale)))))
        try cancellation.check()
        let match=refine(a,b,offset:CGPoint(x:low.offset.x/scale,y:low.offset.y/scale),radius:3)
        guard match.score>0.72,hypot(match.offset.x-expected.x,match.offset.y-expected.y)<=radius+1 else {return nil}
        return match
    }

    /// NCC of gradients suppresses exposure differences and low-frequency lens shading. The
    /// overlap is sampled on a fixed grid to avoid a changing objective during subpixel fitting.
    static func correlation(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint) -> Double {
        let left = max(3,Int(ceil(offset.x))+3), bottom = max(3,Int(ceil(offset.y))+3)
        let right = min(a.width-3,Int(floor(offset.x))+b.width-3)
        let top = min(a.height-3,Int(floor(offset.y))+b.height-3)
        guard right-left > 20, top-bottom > 20 else { return -1 }
        let step = max(2, Int(sqrt(Double((right-left)*(top-bottom))/6000)))
        var aa = 0.0, bb = 0.0, ab = 0.0, count = 0
        for y in stride(from:bottom,to:top,by:step) { for x in stride(from:left,to:right,by:step) {
            let ax = Double(x), ay = Double(y), bx = ax-offset.x, by = ay-offset.y
            let gx = a.sample(ax+1,ay)-a.sample(ax-1,ay), gy = a.sample(ax,ay+1)-a.sample(ax,ay-1)
            let hx = b.sample(bx+1,by)-b.sample(bx-1,by), hy = b.sample(bx,by+1)-b.sample(bx,by-1)
            aa += gx*gx+gy*gy; bb += hx*hx+hy*hy; ab += gx*hx+gy*hy; count += 1
        }}
        guard aa > 1e-5, bb > 1e-5, count > 80 else { return -1 }
        return ab/sqrt(aa*bb)
    }

    /// Each verified corner contributes one normalized patch vote. Moving water, sky, or a
    /// single high-contrast foreground object must not dominate the whole overlap's score.
    private static func localCorrelation(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint, anchors: [CGPoint]) -> Double {
        var scores: [Double] = []
        for p in anchors {
            guard p.x >= 8, p.y >= 8, p.x < Double(a.width-8), p.y < Double(a.height-8),
                  p.x-offset.x >= 8, p.y-offset.y >= 8,
                  p.x-offset.x < Double(b.width-8), p.y-offset.y < Double(b.height-8) else { continue }
            var aa=0.0, bb=0.0, ab=0.0
            for dy in stride(from:-6,through:6,by:3) { for dx in stride(from:-6,through:6,by:3) {
                let x=p.x+Double(dx), y=p.y+Double(dy), u=x-offset.x, v=y-offset.y
                let gx=a.sample(x+1,y)-a.sample(x-1,y), gy=a.sample(x,y+1)-a.sample(x,y-1)
                let hx=b.sample(u+1,v)-b.sample(u-1,v), hy=b.sample(u,v+1)-b.sample(u,v-1)
                aa += gx*gx+gy*gy; bb += hx*hx+hy*hy; ab += gx*hx+gy*hy
            }}
            if aa > 1e-6, bb > 1e-6 { scores.append(ab/sqrt(aa*bb)) }
        }
        guard !scores.isEmpty else { return -1 }
        return median(scores)
    }

    static func refine(_ a: GrayRaster, _ b: GrayRaster, offset: CGPoint, radius: Int, anchors: [CGPoint] = []) -> Match {
        func scoreAt(_ point: CGPoint) -> Double {
            anchors.isEmpty ? correlation(a,b,offset:point) : localCorrelation(a,b,offset:point,anchors:anchors)
        }
        var best = offset, score = scoreAt(offset)
        for dy in -radius...radius { for dx in -radius...radius {
            let p = CGPoint(x:offset.x+Double(dx),y:offset.y+Double(dy))
            let s = scoreAt(p)
            if s > score { best = p; score = s }
        }}
        for step in [0.5,0.25,0.125,0.0625] {
            let center = best
            for dy in -1...1 { for dx in -1...1 {
                let p = CGPoint(x:center.x+Double(dx)*step,y:center.y+Double(dy)*step)
                let s = scoreAt(p)
                if s > score { best = p; score = s }
            }}
        }
        return Match(offset:best,score:score,inliers:0)
    }
}
