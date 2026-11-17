import PhotonsLocalization
import Foundation
import PhotonsFileAccess
import CoreImage

public struct LCCPositionSolution {
    public let offsetMM:CGPoint
    public let explanation:String
    public let flatCount:Int
    public var residual:Double = 0
    public var requiresManualSeed:Bool = false
}

public enum LCCPositionSolver {
    struct Observation {
        let frame:Int
        let point:CGPoint
        let logRGB:SIMD3<Double>
        let field:LCCOrientedField
    }
    public static func solve(plan:PanoramaPlan,fields:[LCCCaptureOrientation:LCCCorrectionField],sensor:SensorSize,
                             cameraBody:PanoramaCameraBody = .alpa12Max,bodyOrientation:PanoramaBodyOrientation = .degrees0,
                             allowPairedFlats:Bool = true, approximateOffset:CGPoint? = nil, searchRadius:Double = 3,
                             cancellation:PanoramaCancellation = .init(),progress:PanoramaEngine.Progress = {_ in}) throws -> LCCPositionSolution {
        let engine=PanoramaEngine(),records=allowPairedFlats ? LCCPairingStore().records():[]
        var observations:[Observation]=[],flats=0
        let w=plan.sources[0].size.width,h=plan.sources[0].size.height
        let centers=plan.sources.indices.map {i in CGPoint(x:(plan.sensorRect(i).midX-plan.size.width/2)*sensor.width/w,
            y:(plan.size.height/2-plan.sensorRect(i).midY)*sensor.height/h)}
        let travel=cameraBody.travel(at:bodyOrientation)
        guard let bounds=travel.opticalOriginBounds(centers:centers) else {
            throw PanoramaFailure(L10n.tr("cd505be730c2" , String(describing: (cameraBody.name)), String(describing: (bodyOrientation.rawValue))))
        }
        let x0=max(bounds.minX,approximateOffset.map {$0.x-searchRadius} ?? bounds.minX)
        let x1=min(bounds.maxX,approximateOffset.map {$0.x+searchRadius} ?? bounds.maxX)
        let y0=max(bounds.minY,approximateOffset.map {$0.y-searchRadius} ?? bounds.minY)
        let y1=min(bounds.maxY,approximateOffset.map {$0.y+searchRadius} ?? bounds.maxY)
        guard x0<=x1,y0<=y1 else {throw PanoramaFailure(L10n.tr("3735a180c3c7"))}

        let flatRecords=plan.sources.map {source in records.first {$0.scene.standardizedFileURL==source.url.standardizedFileURL}}
        let useFlats=flatRecords.contains {$0 != nil}
        for i in plan.sources.indices {
            try cancellation.check()
            guard let orientation=LCCCaptureOrientation(rawValue:plan.sources[i].orientation) else {continue}
            let rotations=cameraBody.equivalentOrientations(to:bodyOrientation)
            guard let rotation=rotations.first(where:{fields[orientation.relative(to:$0)] != nil}),
                  let calibration=fields[orientation.relative(to:rotation)] else {continue}
            let field=LCCOrientedField(field:calibration,bodyOrientation:rotation)
            let image:CIImage
            if useFlats {
                guard let pair=flatRecords[i] else {continue}
                progress(L10n.tr("409ec3974901" , String(describing: (flats+1))))
                let flatAccess=FileAccessStore.shared.access(to:pair.flat)
                        defer {withExtendedLifetime(flatAccess) {}}
                        let source=try PanoramaSource(url:flatAccess.url)
                guard LCCInspector.incompatibility(scene:plan.sources[i],flat:source)==nil else {continue}
                image=field.isCameraSpace ? LCCCameraPipeline.cameraImage(try LCCCameraPipeline.read(source,maxDimension:512)):try LCCProfileBuilder.linearImage(source:source,scale:256/source.size.width);flats += 1
            } else {
                guard let images=plan.lccLinearPreviewImages else {throw PanoramaFailure(L10n.tr("4f3510d3b9ac"))}
                image=images[i]
            }
            let raster=PanoramaRaster(image:image,context:engine.context,width:48,height:36)
            for yy in 2..<34 {for xx in 2..<46 {
                guard let c=raster.rgb(Double(xx),Double(yy)),min(c.x,c.y,c.z)>0.00005 else {continue}
                let p=CGPoint(x:centers[i].x+(Double(xx)/48-0.5)*sensor.width,
                              y:centers[i].y+(0.5-Double(yy)/36)*sensor.height)
                observations.append(.init(frame:i,point:p,logRGB:SIMD3(log(c.x),log(c.y),log(c.z)),field:field))
            }}
        }
        guard observations.count>100 else {throw PanoramaFailure(L10n.tr("fb4baac95a8f"))}
        progress(useFlats ? L10n.tr("3e9dec9a63e9"):L10n.tr("2fdf398a243c"))
        let result=try search(observations:observations,xRange:x0...x1,yRange:y0...y1,flat:useFlats,cancellation:cancellation)
        var explanation=useFlats
            ? String(format:L10n.tr("d44d22cbc3ea"),flats,result.error*100)
            : L10n.tr("32579e8b19fb")
        if min(result.point.x-x0,x1-result.point.x,result.point.y-y0,y1-result.point.y)<0.2 {
            explanation += L10n.tr("6cb863df7b95")
        }
        return LCCPositionSolution(offsetMM:result.point,explanation:explanation,flatCount:flats,residual:result.error,requiresManualSeed:!useFlats && approximateOffset == nil)
    }
    static func search(observations:[Observation],xRange:ClosedRange<Double>,yRange:ClosedRange<Double>,flat:Bool,
                       cancellation:PanoramaCancellation,accept: (CGPoint)->Bool = {_ in true}) throws -> (point:CGPoint,error:Double) {
        func score(_ offset:CGPoint)->Double {
            guard accept(offset) else {return .infinity}
            var groups:[Int:[SIMD3<Double>]]=[:]
            for o in observations {
                guard let g=o.field.gain(at:CGPoint(x:o.point.x-offset.x,y:o.point.y-offset.y)) else {continue}
                let c=o.logRGB+SIMD3(log(g.x),log(g.y),log(g.z))
                groups[o.frame,default:[]].append(SIMD3(c.x-c.y,c.z-c.y,c.y))
            }
            let used=groups.values.reduce(0) {$0+$1.count}
            guard used>observations.count*9/10 else {return .infinity}
            var residuals:[Double]=[]
            for values in groups.values {
                let center=SIMD3(median(values.map(\.x)),median(values.map(\.y)),median(values.map(\.z)))
                for v in values {
                    let d=v-center
                    // Red/green and blue/green carry position information without scene exposure.
                    // Luma is a weaker cue, particularly when the input is not a white plate.
                    residuals.append(sqrt(d.x*d.x+d.y*d.y+(flat ? 0.25:0.04)*d.z*d.z))
                }
            }
            residuals.sort()
            let retained=max(1,Int(Double(residuals.count)*0.85))
            return residuals.prefix(retained).reduce(0,+)/Double(retained)+Double(observations.count-used)/Double(observations.count)*0.5
        }
        var best=CGPoint(x:(xRange.lowerBound+xRange.upperBound)/2,y:(yRange.lowerBound+yRange.upperBound)/2),error=Double.infinity
        for step in [2.0,0.5,0.1] {
            let xr=step==2 ? xRange:max(xRange.lowerBound,best.x-2)...min(xRange.upperBound,best.x+2)
            let yr=step==2 ? yRange:max(yRange.lowerBound,best.y-2)...min(yRange.upperBound,best.y+2)
            let nx=max(1,Int(ceil((xr.upperBound-xr.lowerBound)/step))),ny=max(1,Int(ceil((yr.upperBound-yr.lowerBound)/step)))
            for y in 0...ny {
                try cancellation.check()
                for x in 0...nx {
                    let p=CGPoint(x:xr.lowerBound+Double(x)/Double(nx)*(xr.upperBound-xr.lowerBound),
                                  y:yr.lowerBound+Double(y)/Double(ny)*(yr.upperBound-yr.lowerBound))
                    let e=score(p);if e<error {best=p;error=e}
                }
            }
        }
        guard error.isFinite else {throw PanoramaFailure(L10n.tr("bab9d5b8d021"))}
        return (best,error)
    }
}
