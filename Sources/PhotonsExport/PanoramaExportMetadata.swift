import Foundation
import ImageIO
import PhotonsCore
import PhotonsPanorama

/// Preserve the structural record even when personal metadata is stripped. Compose the same
/// projective geometry used by S0, so resizing, cropping, rotation and perspective remain portable.
public enum PanoramaExportMetadata {
    static let identity:[Double]=[1,0,0,0,1,0,0,0,1]
    static func multiply(_ a:[Double],_ b:[Double])->[Double] {
        (0..<9).map { i in (0..<3).reduce(0) {$0+a[(i/3)*3+$1]*b[$1*3+i%3]} }
    }
    static func geometry(_ edit:EditModel,source:ImageSize)->[Double] {
        let g=CropGeometry(geometry:edit.geometry,source:source)
        let flip:[Double]=[g.flipHorizontal ? -1:1,0,g.flipHorizontal ? 1:0,
                           0,g.flipVertical ? -1:1,g.flipVertical ? 1:0,0,0,1]
        let map:[Double]
        if let pc=g.exportPerspectiveCanvas {
            map=multiply(pc.sampling.flatMap {$0},flip)
        } else {
            let c=g.crop,ratio=Double(g.source.height)/Double(g.source.width)
            let cs=g.cosine,sn=g.inverseSine
            let rotation:[Double]=[cs,-sn*ratio,0.5-0.5*cs+0.5*sn*ratio,
                                   sn/ratio,cs,0.5-0.5*sn/ratio-0.5*cs,0,0,1]
            map=multiply(rotation,multiply(flip,[c.width,0,c.left,0,c.height,c.top,0,0,1]))
        }
        let turn:[Double]
        switch g.quarterTurns {
        case 1: turn=[0,1,0,-1,0,1,0,0,1]
        case 2: turn=[-1,0,1,0,-1,1,0,0,1]
        case 3: turn=[0,-1,1,1,0,0,0,0,1]
        default: turn=identity
        }
        return multiply(turn,map)
    }
    public static func data(for item:ExportItem,source:SourceMetadata?,trimX:Double,trimY:Double,sourceSize:ImageSize? = nil)throws->Data? {
        let packet=item.panoramaMetadata ?? source?.xmp.flatMap {
            (CGImageMetadataCopyStringValueWithPath($0,nil,"photonsPano:Manifest" as CFString) as String?).flatMap {PanoramaMetadataPacket.data($0)}
        }
        guard let packet else {return nil}
        var manifest=try JSONDecoder().decode(PanoramaManifest.self,from:packet)
        try manifest.validate()
        var transform=identity
        if let edit=item.edit,let url=item.sourceURL {
            if let sourceSize {
                transform=geometry(edit,source:sourceSize)
            } else if let source=CGImageSourceCreateWithURL(url as CFURL,nil),
               let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
               let w=props[kCGImagePropertyPixelWidth] as? Int,let h=props[kCGImagePropertyPixelHeight] as? Int,w>0,h>0 {
                transform=geometry(edit,source:.init(width:w,height:h))
            } else if edit.geometry != .identity {manifest.geometryUnrecoverable=true}
        }
        transform=multiply(transform,[trimX,0,0,0,trimY,0,0,0,1])
        manifest.outputTransform=multiply(manifest.outputTransform ?? identity,transform)
        return try manifest.encoded()
    }
}
