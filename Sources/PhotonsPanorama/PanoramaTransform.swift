import Foundation
import CoreGraphics

/// Source pixels → panorama pixels, both in upper-left coordinates.
public struct PanoramaTransform: Codable, Equatable, Sendable {
    public var values: [Double]
    public init(_ values: [Double]) { self.values = values }
    public static let identity = PanoramaTransform([1,0,0,0,1,0,0,0,1])
    public static func translation(_ p: CGPoint) -> Self { Self([1,0,p.x,0,1,p.y,0,0,1]) }
    public static func scale(_ x: Double, _ y: Double) -> Self { Self([x,0,0,0,y,0,0,0,1]) }
    public var isValid: Bool { values.count == 9 && values.allSatisfy(\.isFinite) && inverse != nil }
    public func point(_ p: CGPoint) -> CGPoint {
        let m=values, z=m[6]*p.x+m[7]*p.y+m[8]
        guard abs(z)>1e-12 else { return CGPoint(x:Double.nan,y:Double.nan) }
        return CGPoint(x:(m[0]*p.x+m[1]*p.y+m[2])/z,y:(m[3]*p.x+m[4]*p.y+m[5])/z)
    }
    /// Apply rhs first, then self.
    public func multiplied(by rhs: Self) -> Self {
        var out=[Double](repeating:0,count:9)
        for r in 0..<3 { for c in 0..<3 { for k in 0..<3 { out[r*3+c] += values[r*3+k]*rhs.values[k*3+c] } } }
        let z=out[8]
        if abs(z)>1e-12 { out=out.map {$0/z} }
        return Self(out)
    }
    public var inverse: Self? {
        guard values.count==9 else { return nil }
        let m=values
        let a=m[4]*m[8]-m[5]*m[7], b=m[5]*m[6]-m[3]*m[8], c=m[3]*m[7]-m[4]*m[6]
        let d=m[0]*a+m[1]*b+m[2]*c
        guard d.isFinite,abs(d)>1e-12 else {return nil}
        let result = [a,m[2]*m[7]-m[1]*m[8],m[1]*m[5]-m[2]*m[4],
                     b,m[0]*m[8]-m[2]*m[6],m[2]*m[3]-m[0]*m[5],
                     c,m[1]*m[6]-m[0]*m[7],m[0]*m[4]-m[1]*m[3]].map {$0/d}
        guard result.allSatisfy(\.isFinite) else { return nil }
        return Self(result)
    }
    public func corners(_ size: CGSize) -> [CGPoint] {
        [CGPoint.zero,CGPoint(x:size.width,y:0),CGPoint(x:size.width,y:size.height),CGPoint(x:0,y:size.height)].map(point)
    }
    public func bounds(_ size: CGSize) -> CGRect {
        let p=corners(size),x=p.map(\.x),y=p.map(\.y)
        return CGRect(x:x.min()!,y:y.min()!,width:x.max()!-x.min()!,height:y.max()!-y.min()!)
    }
}
