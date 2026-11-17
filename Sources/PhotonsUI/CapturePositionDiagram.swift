import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

/// One placement diagram for both stitching and profile correction of exported panoramas.
struct CapturePositionDiagram:View {
    struct Frame {
        let name:String
        let center:CGPoint
        let sensor:SensorSize
        var sourceIndex:Int? = nil
    }
    let frames:[Frame]
    let cameraBody:PanoramaCameraBody
    let orientation:PanoramaBodyOrientation
    let absolute:Bool
    var selected:Int?
    var showsTravel=true
    let onSelect:(Int)->Void
    private let colors:[Color]=[.cyan,.purple,.green,.pink,.yellow,.blue]
    private func layout(_ size:CGSize)->(photos:[CGRect],travel:CGRect?) {
        let photos=frames.map {CGRect(x:$0.center.x-$0.sensor.width/2,y:-$0.center.y-$0.sensor.height/2,width:$0.sensor.width,height:$0.sensor.height)}
        let travel=showsTravel ? frames.first.map {cameraBody.travel(at:orientation).coverage(sensor:$0.sensor,centered:!absolute)}:nil
        var bounds=photos.reduce(CGRect.null) {$0.union($1)}
        if let travel {bounds=bounds.union(travel)}
        guard !bounds.isNull,bounds.width>0,bounds.height>0 else {return ([],nil)}
        let scale=min((size.width-28)/bounds.width,(size.height-40)/bounds.height)
        let dx=(size.width-bounds.width*scale)/2-bounds.minX*scale
        let dy=(size.height-bounds.height*scale)/2-bounds.minY*scale+4
        func display(_ r:CGRect)->CGRect {CGRect(x:r.minX*scale+dx,y:r.minY*scale+dy,width:r.width*scale,height:r.height*scale)}
        return (photos.map(display),travel.map(display))
    }
    var body:some View {
        GeometryReader {proxy in
            let placement=layout(proxy.size)
            Canvas {context,size in
                if let travel=placement.travel {
                    context.stroke(Path(travel),with:.color(.primary.opacity(0.65)),style:StrokeStyle(lineWidth:1.2,dash:[5,3]))
                    context.draw(Text(L10n.tr("fe8af84b5fd4",cameraBody.name,String(orientation.rawValue))).font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:travel.midX,y:travel.minY-9))
                }
                for i in placement.photos.indices {
                    let rect=placement.photos[i],frame=frames[i],color=colors[i%colors.count]
                    let outside=absolute && showsTravel && !cameraBody.travel(at:orientation).contains(frame.center)
                    context.fill(Path(rect),with:.color(color.opacity(0.14)))
                    context.stroke(Path(rect),with:.color(outside ? .orange:color),lineWidth:selected==(frame.sourceIndex ?? i) ? 2.5:1.2)
                    context.draw(Text(frame.name).font(.system(size:10,weight:.medium)),at:CGPoint(x:rect.midX,y:rect.midY))
                    if showsTravel {
                        let text=String(format:absolute ? "X %+.1f · Y %+.1f mm":"Δ %+.1f, %+.1f mm",frame.center.x,frame.center.y)
                        context.draw(Text(text).font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:rect.midX,y:rect.midY+13))
                    }
                }
                if !absolute {context.draw(Text(L10n.tr("00964853f102")).font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:size.width/2,y:size.height-8))}
            }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded {event in
                let choices=placement.photos.indices.filter {placement.photos[$0].contains(event.location)}
                if let i=choices.min(by:{hypot(placement.photos[$0].midX-event.location.x,placement.photos[$0].midY-event.location.y)<hypot(placement.photos[$1].midX-event.location.x,placement.photos[$1].midY-event.location.y)}) {onSelect(frames[i].sourceIndex ?? i)}
            })
        }.accessibilityIdentifier("lcc.placementDiagram")
    }
}
