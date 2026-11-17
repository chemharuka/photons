import PhotonsLocalization
import SwiftUI
import PhotonsPanorama

/// The same compact placement control is used by stitching and LCC creation.
struct PanoramaBodyOrientationPicker:View {
    let cameraBody:PanoramaCameraBody
    @Binding var selection:PanoramaBodyOrientation
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:5) {
                ForEach(cameraBody.orientations) {angle in
                    Button {selection=angle} label: {
                        VStack(spacing:5) {
                            diagram(angle).frame(height:42)
                            Text("\(angle.rawValue)° \(cameraBody.placementLabel(angle))")
                                .font(.system(size:10)).lineLimit(1).minimumScaleFactor(0.8)
                        }.padding(.vertical,8).padding(.horizontal,3).frame(maxWidth:.infinity)
                            .background(selection==angle ? Color.accentColor.opacity(0.16):Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:7))
                            .overlay(RoundedRectangle(cornerRadius:7).stroke(selection==angle ? Color.accentColor:Color.secondary.opacity(0.3),lineWidth:selection==angle ? 1.5:0.6))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("c0a3dfc3ae3e" , String(describing: (angle.rawValue)), String(describing: (cameraBody.placementLabel(angle)))))
                        .accessibilityValue(selection==angle ? L10n.tr("3f4ebc4aad97"):L10n.tr("1182c5454f11"))
                        .accessibilityIdentifier("panorama.body.orientation.\(angle.rawValue)")
                }
            }
            Text(L10n.tr("444399a3f9ce")).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func diagram(_ angle:PanoramaBodyOrientation)->some View {
        Canvas {context,size in
            let travel=cameraBody.travel(at:angle)
            // A small footprint gives single-axis bodies a visible rectangular outline.
            let range=travel.coverage(sensor:SensorSize(width:12,height:12,source:L10n.tr("65c83dfb4727")),centered:false)
            let scale=min(52/range.width,34/range.height)
            let center=CGPoint(x:size.width/2,y:size.height/2)
            let rect=CGRect(x:center.x-range.width*scale/2,y:center.y-range.height*scale/2,width:range.width*scale,height:range.height*scale)
            let zero=CGPoint(x:rect.minX-range.minX*scale,y:rect.minY-range.minY*scale)
            let color:Color=selection==angle ? .accentColor:.primary
            context.fill(Path(rect),with:.color(color.opacity(0.08)))
            context.stroke(Path(rect),with:.color(color.opacity(0.8)),lineWidth:1.3)
            var cross=Path();cross.move(to:CGPoint(x:zero.x-4,y:zero.y));cross.addLine(to:CGPoint(x:zero.x+4,y:zero.y))
            cross.move(to:CGPoint(x:zero.x,y:zero.y-4));cross.addLine(to:CGPoint(x:zero.x,y:zero.y+4))
            context.stroke(cross,with:.color(color),lineWidth:1.3)
        }.accessibilityHidden(true)
    }
}
