import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Raster sources (including gain-map JPEG/HEIC) enter the same edit graph as RAW sources.
/// Decode to extended linear sRGB before editing; an SDR thumbnail would discard the gain map.
public enum ImageSourceDecoder {
    public static func isRAW(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return true }
        return UTType(type as String)?.conforms(to: .rawImage) == true
    }

    public static func size(at url: URL) throws -> ImageSize {
        if isRAW(url) {
            let probe = try RAWDecoder().probe(url)
            return ImageSize(width: probe.nativeWidth, height: probe.nativeHeight)
        }
        let image = try raster(at: url)
        return ImageSize(width: Int(image.extent.width), height: Int(image.extent.height))
    }

    private static func raster(at url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]),
              !image.extent.isInfinite, !image.extent.isEmpty else { throw DecodeError.unsupportedFile(url) }
        return image
    }

    public static func decodeRaster(_ url: URL, scale: Float) throws -> LinearImage {
        var image = try raster(at: url)
        let width = max(1, Int((image.extent.width * CGFloat(scale)).rounded()))
        let height = max(1, Int((image.extent.height * CGFloat(scale)).rounded()))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                               y: CGFloat(height) / image.extent.height), highQualityDownsample: true)
        // CIContext's bitmap destination is already top-row-first. Unlike the RAW decoder's
        // Metal texture destination, it must not receive an extra vertical reflection.
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 8,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAh, colorSpace: space)
        return LinearImage(width: width, height: height, rgba: pixels,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "ImageIO-HDR")
    }
}
