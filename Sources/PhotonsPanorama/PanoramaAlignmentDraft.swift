import Foundation

extension PanoramaEngine {
    /// A selectable layout after unsuccessful registration. It is explicitly not a stitch plan
    /// and cannot be rendered/exported; it lets the user enter rescue measurements for any frame.
    public func alignmentDraft(urls:[URL],knownPositions:[Int:CGPoint],sensorOverride:SensorSize?,message:String,
                               cancellation:PanoramaCancellation = .init()) throws -> PanoramaPlan {
        guard (2...16).contains(urls.count) else {throw PanoramaFailure(message)}
        let sources=try urls.map {url in try cancellation.check();return try PanoramaSource(url:url)}
        let first=sources[0],sensor=sensorOverride ?? first.sensor
        var origins=sources.indices.map {i->CGPoint in
            if let p=knownPositions[i],let sensor {
                return CGPoint(x:p.x/sensor.width*first.size.width,y:-p.y/sensor.height*first.size.height)
            }
            return CGPoint(x:Double(i%4)*first.size.width*0.8,y:Double(i/4)*first.size.height*0.8)
        }
        let left=origins.map(\.x).min()!,top=origins.map(\.y).min()!
        origins=origins.map {CGPoint(x:$0.x-left,y:$0.y-top)}
        let size=CGSize(width:origins.map(\.x).max()!+first.size.width,height:origins.map(\.y).max()!+first.size.height)
        var plan=PanoramaPlan(sources:sources,origins:origins,size:size,registrationScores:[Double](repeating:0,count:sources.count),whiteBalance:nil,
            gains:[Double](repeating:1,count:sources.count),ownership:[],maskWidth:0,maskHeight:0,
            optical:.init(center:nil,confidence:0,explanation:message,occludedEdges:[]),options:.init(),previewScale:1,previewImages:[],preview:nil)
        plan.isRegistered=false
        return plan
    }
}
