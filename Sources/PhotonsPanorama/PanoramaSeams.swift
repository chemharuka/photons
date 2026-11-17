import PhotonsLocalization
import Foundation
import CoreImage
import Vision

enum PanoramaSeams {
    static func prepare(_ plan: inout PanoramaPlan, context: CIContext, cancellation: PanoramaCancellation) throws {
        let scale = min(1,1000/max(plan.size.width,plan.size.height))
        let w = Int(ceil(plan.size.width*scale)), h = Int(ceil(plan.size.height*scale)), count = w*h
        let sx = Double(w)/plan.size.width, sy = Double(h)/plan.size.height
        let rasters = plan.previewImages.map {
            PanoramaRaster(image:$0,context:context,width:max(24,Int($0.extent.width/plan.previewScale*sx)),
                           height:max(24,Int($0.extent.height/plan.previewScale*sy)))
        }
        let n = rasters.count
        var colors = [[SIMD3<Double>]](repeating:[SIMD3<Double>](repeating:.zero,count:count),count:n)
        var valid = [[Bool]](repeating:[Bool](repeating:false,count:count),count:n)
        var edgeCost = [[Double]](repeating:[Double](repeating:1000,count:count),count:n)
        var occluded: [String] = []
        for i in 0..<n {
            try cancellation.check()
            let raster = rasters[i]
            let inverse = (plan.warps?[i] ?? .translation(plan.origins[i])).inverse!
            var blackEdges = 0
            for y in 0..<h { for x in 0..<w {
                let local=inverse.point(CGPoint(x:(Double(x)+0.5)/sx,y:(Double(y)+0.5)/sy))
                let lx=local.x/plan.sources[i].size.width*Double(raster.width),ly=local.y/plan.sources[i].size.height*Double(raster.height),p=y*w+x
                guard let c = raster.rgb(lx,ly) else { continue }
                let luma = (c.x+c.y+c.z)/3
                let distance = min(lx,ly,Double(raster.width)-1-lx,Double(raster.height)-1-ly)
                // Physical shutters/masks give almost-zero values on the sensor border. Do not
                // interpret an ordinary dark subject in the interior as an occluded sensor.
                if distance < Double(min(raster.width,raster.height))*0.035 && luma < 0.0007 {
                    blackEdges += 1; continue
                }
                colors[i][p] = c; valid[i][p] = true
                edgeCost[i][p] = 0.12 / (0.025 + distance/Double(min(raster.width,raster.height)))
            }}
            if blackEdges > 20 { occluded.append(plan.sources[i].url.lastPathComponent) }
        }
        // Robust gains from scene-identical overlap samples. The same gain is applied to full RAW.
        var gains = [Double](repeating:1,count:n), solved: Set<Int> = [0]
        for _ in 1..<n {
            var candidate: (Int,Double,Int)?
            for a in solved { for b in 0..<n where !solved.contains(b) {
                var ratios: [Double] = []
                for p in stride(from:0,to:count,by:7) where valid[a][p] && valid[b][p] {
                    let ca = colors[a][p], cb = colors[b][p]
                    let la = (ca.x+ca.y+ca.z)/3, lb = (cb.x+cb.y+cb.z)/3
                    if la > 0.005 && lb > 0.005 && la < 0.9 && lb < 0.9 { ratios.append(log(la/lb)) }
                }
                if ratios.count > 30, candidate == nil || ratios.count > candidate!.2 {
                    candidate = (b,gains[a]*exp(median(ratios)),ratios.count)
                }
            }}
            if let c = candidate { gains[c.0] = min(4,max(0.25,c.1)); solved.insert(c.0) }
        }
        plan.gains = plan.options.matchExposure ? gains : [Double](repeating:1,count:n)
        for i in 0..<n { for p in 0..<count { colors[i][p] *= plan.gains[i] } }
        plan.photometricGains=[]
        if plan.options.matchExposure && plan.lccState == nil {
            func local(_ i:Int,_ p:Int)->CGPoint {
                let point=plan.sourcePoint(i,panorama:CGPoint(x:(Double(p%w)+0.5)/sx,y:(Double(p/w)+0.5)/sy))
                return CGPoint(x:point.x/plan.sources[i].size.width-0.5,y:point.y/plan.sources[i].size.height-0.5)
            }
            var samples:[PanoramaPhotometry.Sample]=[]
            for a in 0..<n {for b in a+1..<n {
                try cancellation.check()
                for y in stride(from:0,to:h,by:5) {for x in stride(from:0,to:w,by:5) {
                    let p=y*w+x
                    guard valid[a][p],valid[b][p] else {continue}
                    let pa=local(a,p),pb=local(b,p),ca=colors[a][p],cb=colors[b][p]
                    guard max(abs(pa.x),abs(pa.y),abs(pb.x),abs(pb.y))<0.45,
                          min(ca.x,ca.y,ca.z,cb.x,cb.y,cb.z)>0.004,
                          max(ca.x,ca.y,ca.z,cb.x,cb.y,cb.z)<4 else {continue}
                    samples.append(.init(a:a,b:b,ax:pa.x,ay:pa.y,bx:pb.x,by:pb.y,
                        difference:SIMD3(log(cb.x/ca.x),log(cb.y/ca.y),log(cb.z/ca.z))))
                }}
            }}
            let planes=PanoramaPhotometry.fit(samples,count:n)
            for i in 0..<n {
                plan.photometricGains.append(PanoramaPhotometry.image(planes[i],size:plan.sources[i].size))
                for p in 0..<count where valid[i][p] {
                    let q=local(i,p);colors[i][p] *= planes[i].gain(q.x,q.y)
                }
            }
        }
        var unary = edgeCost
        var disagreement = [Double](repeating:0,count:count)
        for p in 0..<count {
            let choices = (0..<n).filter { valid[$0][p] }
            guard choices.count > 1 else { continue }
            let center = SIMD3(median(choices.map { colors[$0][p].x }),median(choices.map { colors[$0][p].y }),median(choices.map { colors[$0][p].z }))
            let normalizer = 0.025+(center.x+center.y+center.z)/3
            for i in choices {
                let d = colors[i][p]-center
                let error = sqrt(d.x*d.x+d.y*d.y+d.z*d.z)/normalizer
                disagreement[p] = max(disagreement[p],error)
                if plan.options.avoidMotion, choices.count >= 3 { unary[i][p] += min(8,error*4) }
                if i == plan.options.preferredSource { unary[i][p] -= 4 }
            }
        }
        if plan.options.avoidMotion {
            // Semantics resolves the two-frame ambiguity for people: prefer another observation
            // of the same region without a person. Vehicles rely on consensus/seams or user choice.
            for i in 0..<n {
                try cancellation.check()
                let request = VNDetectHumanRectanglesRequest(); request.upperBodyOnly = false
                if let cg = context.createCGImage(plan.previewImages[i],from:plan.previewImages[i].extent) {
                    try? VNImageRequestHandler(cgImage:cg).perform([request])
                    for person in request.results ?? [] where person.confidence > 0.55 {
                        let box = person.boundingBox.insetBy(dx:-0.025,dy:-0.025)
                        let sourceSize=plan.sources[i].size
                        let local=CGRect(x:box.minX*sourceSize.width,y:(1-box.maxY)*sourceSize.height,width:box.width*sourceSize.width,height:box.height*sourceSize.height)
                        let warp=plan.warps?[i] ?? .translation(plan.origins[i])
                        let p=[CGPoint(x:local.minX,y:local.minY),CGPoint(x:local.maxX,y:local.minY),CGPoint(x:local.maxX,y:local.maxY),CGPoint(x:local.minX,y:local.maxY)].map {warp.point($0)}
                        let rect=CGRect(x:p.map(\.x).min()!*sx,y:p.map(\.y).min()!*sy,width:(p.map(\.x).max()!-p.map(\.x).min()!)*sx,height:(p.map(\.y).max()!-p.map(\.y).min()!)*sy)
                        for y in max(0,Int(rect.minY))..<min(h,max(0,Int(ceil(rect.maxY)))) {
                            for x in max(0,Int(rect.minX))..<min(w,max(0,Int(ceil(rect.maxX)))) { unary[i][y*w+x] += 8 }
                        }
                    }
                }
            }
        }
        var labels = [Int16](repeating:-1,count:count)
        for p in 0..<count {
            if let best = (0..<n).filter({ valid[$0][p] }).min(by: { unary[$0][p] < unary[$1][p] }) { labels[p] = Int16(best) }
        }
        // Potts label optimization. A boundary is expensive through a disagreement region, causing
        // the seam to go around it. The field is two-dimensional; there is no straight-seam limit.
        for pass in 0..<10 {
            try cancellation.check(); var changed = 0
            let indices: AnySequence<Int> = pass % 2 == 0 ? AnySequence(0..<count) : AnySequence((0..<count).reversed())
            for p in indices where labels[p] >= 0 {
                let x = p%w, y = p/w
                let neighbors = [x>0 ? p-1:-1,x<w-1 ? p+1:-1,y>0 ? p-w:-1,y<h-1 ? p+w:-1].filter { $0 >= 0 && labels[$0] >= 0 }
                var best = Int(labels[p]), bestEnergy = Double.infinity
                for i in 0..<n where valid[i][p] {
                    var energy = unary[i][p]
                    for q in neighbors where labels[q] != Int16(i) {
                        energy += plan.options.avoidMotion ? 0.65+min(6,max(disagreement[p],disagreement[q])*5) : 0.4
                    }
                    if energy < bestEnergy { bestEnergy = energy; best = i }
                }
                if labels[p] != Int16(best) { labels[p] = Int16(best); changed += 1 }
            }
            if changed == 0 { break }
        }
        plan.maskWidth = w; plan.maskHeight = h; plan.ownership = labels
        let radius = max(0,min(16,Int(plan.options.seamSoftness)))
        var unsafe = disagreement.map { Float($0 > 0.3 ? 1:0) }
        if radius > 0 { unsafe = boxBlur(unsafe,width:w,height:h,radius:radius*2) }
        var weights: [[Float]] = []
        for i in 0..<n {
            let hard = labels.map { Float($0 == Int16(i) ? 1:0) }
            var soft = radius > 0 ? boxBlur(hard,width:w,height:h,radius:radius) : hard
            for p in 0..<count {
                if !valid[i][p] || labels[p] < 0 { soft[p] = 0 }
                else if plan.options.avoidMotion {
                    // Continuous transition to ownership near disagreement. A binary switch
                    // from feathered to hard masks itself creates a visible brightness step.
                    let protect=min(1,unsafe[p]*8)
                    soft[p]=soft[p]*(1-protect)+hard[p]*protect
                }
            }
            weights.append(soft)
        }
        for p in 0..<count {
            let sum = weights.reduce(Float(0)) { $0+$1[p] }
            if sum > 0 { for i in 0..<n { weights[i][p] /= sum } }
        }
        plan.blendMasks = weights.map { $0.withUnsafeBytes { Data($0) } }
        plan.optical = OpticalPositionEstimator.estimate(rasters:rasters,origins:plan.origins,scaleX:sx,scaleY:sy,size:plan.size,occluded:occluded)
    }

    private static func boxBlur(_ input:[Float],width:Int,height:Int,radius:Int) -> [Float] {
        var horizontal = input, output = input
        for y in 0..<height {
            var sum:Float = 0
            for x in -radius..<width+radius {
                if x+radius < width { sum += input[y*width+x+radius] }
                if x-radius-1 >= 0 { sum -= input[y*width+x-radius-1] }
                if x>=0 && x<width { horizontal[y*width+x] = sum/Float(min(width-1,x+radius)-max(0,x-radius)+1) }
            }
        }
        for x in 0..<width {
            var sum:Float = 0
            for y in -radius..<height+radius {
                if y+radius < height { sum += horizontal[(y+radius)*width+x] }
                if y-radius-1 >= 0 { sum -= horizontal[(y-radius-1)*width+x] }
                if y>=0 && y<height { output[y*width+x] = sum/Float(min(height-1,y+radius)-max(0,y-radius)+1) }
            }
        }
        return output
    }
}

/// Fit log-light and red/green fields to a common quadratic bowl. Scene content can mimic lens
/// shading, so report only a conservative candidate with cross-channel agreement. Calibration
/// with a flat-field/LCC is intentionally separate from this scene-based estimate.
enum OpticalPositionEstimator {
    static func estimate(rasters: [PanoramaRaster], origins: [CGPoint], scaleX: Double, scaleY: Double,
                         size: CGSize, occluded: [String]) -> OpticalEstimate {
        var fits: [(CGPoint, Double)] = []
        for channel in 0...1 {
            var rows: [[Double]] = [], values: [Double] = []
            for (i,raster) in rasters.enumerated() {
                // Per-image intercept absorbs exposure/WB. Quadratic and linear terms are shared.
                for y in stride(from:8,to:raster.height-8,by:16) { for x in stride(from:8,to:raster.width-8,by:16) {
                    guard let c = raster.rgb(Double(x),Double(y)), c.x>0.003,c.y>0.003,c.z>0.003,
                          max(c.x,c.y,c.z)<0.95 else { continue }
                    let gx = (Double(x)/scaleX+origins[i].x)/size.width-0.5
                    let gy = (Double(y)/scaleY+origins[i].y)/size.width-size.height/size.width/2
                    var row = [gx*gx+gy*gy,gx,gy]+[Double](repeating:0,count:rasters.count)
                    row[3+i] = 1; rows.append(row)
                    values.append(channel == 0 ? log((c.x+c.y+c.z)/3) : log(c.x/c.y))
                }}
            }
            guard let fit = solve(rows,values), abs(fit[0])>0.12,
                  channel != 0 || fit[0] < 0 else { continue }
            let cx = -fit[1]/(2*fit[0]), cy = -fit[2]/(2*fit[0])
            guard abs(cx)<0.7, abs(cy)<0.7 else { continue }
            let residual = median(zip(rows,values).map { row,value in abs(zip(row,fit).reduce(0) { $0+$1.0*$1.1 }-value) })
            fits.append((CGPoint(x:(cx+0.5)*size.width,y:cy*size.width+size.height/2),residual))
        }
        if fits.count == 2, hypot(fits[0].0.x-fits[1].0.x,fits[0].0.y-fits[1].0.y)<size.width*0.12,
           fits[0].1<0.2, fits[1].1<0.12 {
            return OpticalEstimate(center:CGPoint(x:(fits[0].0.x+fits[1].0.x)/2,y:(fits[0].0.y+fits[1].0.y)/2),
                                   confidence:0.45,explanation:L10n.tr("4a14b51acd0b"),occludedEdges:occluded)
        }
        return OpticalEstimate(center:nil,confidence:0,explanation:L10n.tr("0df4a9d36d96"),occludedEdges:occluded)
    }
    static func solve(_ rows: [[Double]], _ values: [Double]) -> [Double]? {
        guard let first = rows.first, rows.count > first.count*3 else { return nil }
        let n = first.count
        var matrix = [[Double]](repeating:[Double](repeating:0,count:n+1),count:n)
        for (row,value) in zip(rows,values) { for a in 0..<n {
            for b in 0..<n { matrix[a][b] += row[a]*row[b] }
            matrix[a][n] += row[a]*value
        }}
        for k in 0..<n {
            let pivot = (k..<n).max { abs(matrix[$0][k]) < abs(matrix[$1][k]) }!
            matrix.swapAt(k,pivot)
            guard abs(matrix[k][k])>1e-8 else { return nil }
            let d = matrix[k][k]; for j in k...n { matrix[k][j] /= d }
            for i in 0..<n where i != k { let f = matrix[i][k]; for j in k...n { matrix[i][j] -= f*matrix[k][j] } }
        }
        return matrix.map { $0[n] }
    }
}
