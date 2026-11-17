import Foundation
import CoreImage
import simd

/// A stable, hue-preserving SDR shoulder, shared by interactive Metal preview and exports.
/// It depends only on the pixel, so zoom, crop, tile boundaries and output size cannot change
/// the exposure. Values below 0.8 remain unchanged; highlights approach SDR white smoothly.
public enum SDRProjection {
    public static func map(_ rgb:SIMD3<Float>)->SIMD3<Float> {
        let v=SIMD3(rgb.x.isFinite ? max(0,rgb.x):0,rgb.y.isFinite ? max(0,rgb.y):0,rgb.z.isFinite ? max(0,rgb.z):0)
        let peak=max(v.x,v.y,v.z)
        guard peak>0.8 else {return v}
        let mapped:Float=0.8+0.2*(peak-0.8)/(peak-0.6)
        return v*(mapped/peak)
    }
    public static func fromWorking(_ rgb:SIMD3<Float>,primaries:OutputPrimaries = .displayP3)->SIMD3<Float> {
        let m=RenderGraph.primariesMatrix(from:ColorPrimaries.working,to:RenderGraph.outputPrimaries(primaries))
        let v=m*SIMD4(rgb.x,rgb.y,rgb.z,0)
        return map(SIMD3(v.x,v.y,v.z))
    }
    public static func pixels(_ rgba:[Float16])->[Float16] {
        var out=rgba
        for i in stride(from:0,to:out.count,by:4) {
            let rgb=map(SIMD3(Float(out[i]),Float(out[i+1]),Float(out[i+2])))
            out[i]=Float16(rgb.x);out[i+1]=Float16(rgb.y);out[i+2]=Float16(rgb.z)
        }
        return out
    }
    public static func histogram(_ sample:LinearSample,bins:Int,rect:ImageRect?,primaries:OutputPrimaries)->Histogram {
        let matrix=RenderGraph.primariesMatrix(from:ColorPrimaries.working,to:RenderGraph.outputPrimaries(primaries))
        var values=sample.rgba
        for i in stride(from:0,to:values.count,by:4) {
            let v=matrix*SIMD4(Float(values[i]),Float(values[i+1]),Float(values[i+2]),0)
            let rgb=map(SIMD3(v.x,v.y,v.z))
            for c in 0..<3 {let x=rgb[c];values[i+c]=Float16(x<=0.0031308 ? 12.92*x:1.055*pow(x,1/2.4)-0.055)}
        }
        return Histogram.compute(DisplayImage(width:sample.width,height:sample.height,rgba:values,primaries:primaries,bitDepth:16),bins:bins,rect:rect,headroom:1)
    }
    private static let kernel=CIColorKernel(source:"""
        kernel vec4 photonsSDR(__sample s) {
            vec3 v=max(s.rgb,vec3(0.0));
            float p=max(v.r,max(v.g,v.b));
            float mapped=0.8+0.2*(p-0.8)/max(0.0001,p-0.6);
            return vec4(p>0.8 ? v*(mapped/p):v,s.a);
        }
        """)!
    public static func image(_ image:CIImage)->CIImage {kernel.apply(extent:image.extent,arguments:[image])!}
}
