import Foundation
import CoreGraphics

/// A fallback for small camera rotation/tilt. Geometry needs both descriptor consensus and
/// independent subpixel patch agreement; an entered shift cannot manufacture a successful fit.
enum ProjectiveRegistration {
    struct Pair { var a: CGPoint; var b: CGPoint }
    struct Match { var transform: PanoramaTransform; var score: Double; var pairs: [Pair] }

    static func align(_ a: GrayRaster, _ b: GrayRaster, fineA: GrayRaster, fineB: GrayRaster,
                      cancellation: PanoramaCancellation) throws -> Match? {
        let pairs = try TranslationRegistration.correspondences(a,b,cancellation:cancellation)
        guard let initial = try robust(pairs, width: Double(a.width), height: Double(a.height), cancellation: cancellation) else { return nil }
        let sx=Double(fineA.width)/Double(a.width),sy=Double(fineA.height)/Double(a.height)
        var refined: [Pair]=[], scores: [Double]=[]
        for (i,p) in initial.pairs.enumerated() {
            if i % 16 == 0 {try cancellation.check()}
            let ap=CGPoint(x:p.a.x*sx,y:p.a.y*sy),bp=CGPoint(x:p.b.x*sx,y:p.b.y*sy)
            let match=TranslationRegistration.refine(fineA,fineB,offset:CGPoint(x:ap.x-bp.x,y:ap.y-bp.y),radius:3,anchors:[ap])
            guard match.score>0.8 else {continue}
            refined.append(Pair(a:ap,b:CGPoint(x:ap.x-match.offset.x,y:ap.y-match.offset.y)));scores.append(match.score)
        }
        guard var result=try robust(refined,width:Double(fineA.width),height:Double(fineA.height),cancellation:cancellation),
              result.pairs.count>=12 else {return nil}
        result.score=median(scores)
        return result
    }

    static func robust(_ pairs: [Pair], width: Double, height: Double,
                       cancellation: PanoramaCancellation = .init()) throws -> Match? {
        guard pairs.count>=12,width>0,height>0 else {return nil}
        let normalization=PanoramaTransform.scale(1/width,1/height)
        let denormalization=PanoramaTransform.scale(width,height)
        let normalized=pairs.map {Pair(a:normalization.point($0.a),b:normalization.point($0.b))}
        var seed: UInt64=0x93729a4d, best:[Int]=[]
        func random(_ count:Int)->Int {seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Int((seed>>32)%UInt64(count))}
        for iteration in 0..<1800 {
            if iteration%100==0 {try cancellation.check()}
            var indices=Set<Int>();while indices.count<4 {indices.insert(random(pairs.count))}
            guard let h=fit(indices.map {normalized[$0]}) else {continue}
            let full=denormalization.multiplied(by:h).multiplied(by:normalization)
            let inliers=pairs.indices.filter {distance(full.point(pairs[$0].b),pairs[$0].a)<2.5}
            if inliers.count>best.count {best=inliers}
            if best.count>Int(Double(pairs.count)*0.85),iteration>100 {break}
        }
        guard best.count>=12,best.count>=pairs.count/6 else {return nil}
        var result:PanoramaTransform?
        for _ in 0..<3 {
            guard let h=fit(best.map {normalized[$0]}) else {return nil}
            let full=denormalization.multiplied(by:h).multiplied(by:normalization)
            result=full
            best=pairs.indices.filter {distance(full.point(pairs[$0].b),pairs[$0].a)<2.5}
        }
        guard let result,best.count>=12 else {return nil}
        let inliers=best.map {pairs[$0]}
        // Spread matters: a tiny repeated window must not determine the entire image warp.
        let x=inliers.map {$0.b.x},y=inliers.map {$0.b.y}
        guard (x.max()!-x.min()!)*(y.max()!-y.min()!)>width*height*0.025 else {return nil}
        let corners=result.corners(CGSize(width:width,height:height))
        guard corners.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return nil}
        let denominators=[CGPoint.zero,CGPoint(x:width,y:0),CGPoint(x:width,y:height),CGPoint(x:0,y:height)].map {result.values[6]*$0.x+result.values[7]*$0.y+result.values[8]}
        guard denominators.allSatisfy({$0>0.25 && $0<4}) else {return nil}
        var area=0.0
        for i in 0..<4 {let p=corners[i],q=corners[(i+1)%4];area += p.x*q.y-q.x*p.y}
        guard area>width*height,area<width*height*4 else {return nil} // oriented area, twice the area
        return Match(transform:result,score:0,pairs:inliers)
    }

    private static func distance(_ a:CGPoint,_ b:CGPoint)->Double {hypot(a.x-b.x,a.y-b.y)}
    private static func fit(_ pairs:[Pair])->PanoramaTransform? {
        var m=[[Double]](repeating:[Double](repeating:0,count:9),count:8)
        for p in pairs {
            let x=p.b.x,y=p.b.y,u=p.a.x,v=p.a.y
            for (row,value) in [([x,y,1,0,0,0,-u*x,-u*y],u),([0,0,0,x,y,1,-v*x,-v*y],v)] {
                for i in 0..<8 {for j in 0..<8 {m[i][j] += row[i]*row[j]};m[i][8] += row[i]*value}
            }
        }
        for k in 0..<8 {
            let pivot=(k..<8).max {abs(m[$0][k])<abs(m[$1][k])}!
            m.swapAt(k,pivot);let d=m[k][k]
            guard abs(d)>1e-10 else {return nil}
            for j in k...8 {m[k][j] /= d}
            for i in 0..<8 where i != k {let f=m[i][k];for j in k...8 {m[i][j] -= f*m[k][j]}}
        }
        let h=PanoramaTransform(m.map {$0[8]}+[1])
        return h.isValid ? h:nil
    }
}
