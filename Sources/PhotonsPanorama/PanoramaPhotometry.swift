import Foundation
import CoreImage

/// Fit only slowly varying residual RGB exposure from the *same scene points* in overlaps.
/// Robust plane fitting excludes sensor borders and downweights moving objects/edge residuals.
/// It cannot warp geometry or erase texture; the frozen fields are reused by full-size export.
enum PanoramaPhotometry {
    struct Sample {
        let a:Int,b:Int
        let ax:Double,ay:Double,bx:Double,by:Double
        let difference:SIMD3<Double>
    }
    struct Plane {
        var constant=SIMD3<Double>.zero,x=SIMD3<Double>.zero,y=SIMD3<Double>.zero
        func gain(_ u:Double,_ v:Double)->SIMD3<Double> {
            let d=constant+x*u+y*v
            return SIMD3(exp(min(0.45,max(-0.45,d.x))),exp(min(0.45,max(-0.45,d.y))),exp(min(0.45,max(-0.45,d.z))))
        }
    }
    static func fit(_ samples:[Sample],count:Int)->[Plane] {
        guard !samples.isEmpty else {return [Plane](repeating:Plane(),count:count)}
        let n=count*3
        var planes=[Plane](repeating:Plane(),count:count)
        for channel in 0..<3 {
            var coefficients=[Double](repeating:0,count:n)
            for _ in 0..<4 {
                var matrix=[[Double]](repeating:[Double](repeating:0,count:n+1),count:n)
                // Fix the otherwise free common-field gauge with a weak identity prior.
                let prior=max(1,Double(samples.count)/Double(count)*0.005)
                for k in 0..<n {matrix[k][k]=k%3==0 ? prior*0.02:prior}
                for s in samples {
                    let indices=[s.a*3,s.a*3+1,s.a*3+2,s.b*3,s.b*3+1,s.b*3+2]
                    let row=[1,s.ax,s.ay,-1,-s.bx,-s.by]
                    let value=s.difference[channel]
                    let prediction=zip(indices,row).reduce(0) {$0+coefficients[$1.0]*$1.1}
                    let weight=min(1,0.06/max(1e-9,abs(value-prediction)))
                    for i in 0..<6 {
                        let k=indices[i],v=row[i]*weight
                        for j in 0..<6 {matrix[k][indices[j]] += v*row[j]}
                        matrix[k][n] += v*value
                    }
                }
                for k in 0..<n {
                    let pivot=(k..<n).max {abs(matrix[$0][k])<abs(matrix[$1][k])}!
                    matrix.swapAt(k,pivot)
                    let d=matrix[k][k];guard abs(d)>1e-12 else {continue}
                    for j in k...n {matrix[k][j] /= d}
                    for i in 0..<n where i != k {
                        let f=matrix[i][k]
                        for j in k...n {matrix[i][j] -= f*matrix[k][j]}
                    }
                }
                coefficients=matrix.map {$0[n]}
            }
            for i in 0..<count {
                planes[i].constant[channel]=coefficients[i*3]
                planes[i].x[channel]=coefficients[i*3+1];planes[i].y[channel]=coefficients[i*3+2]
            }
        }
        return planes
    }
    static func image(_ plane:Plane,size:CGSize)->CIImage {
        let w=64,h=64
        var pixels=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let g=plane.gain((Double(x)+0.5)/Double(w)-0.5,(Double(y)+0.5)/Double(h)-0.5),j=(y*w+x)*4
            pixels[j]=Float(g.x);pixels[j+1]=Float(g.y);pixels[j+2]=Float(g.z)
        }}
        return CIImage(bitmapData:pixels.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .transformed(by:CGAffineTransform(scaleX:size.width/Double(w),y:size.height/Double(h)))
    }
}
