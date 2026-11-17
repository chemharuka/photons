import XCTest
import CoreImage
import ImageIO
@testable import PhotonsPanorama

final class PanoramaToneTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: PanoramaEngine.linearSpace])
    private func scene(_ peak: Double = 20, width: Double = 10) -> CIImage {
        func color(_ value: Double) -> CIColor {
            CIColor(red: value,green: value * 0.5,blue: value * 0.2,alpha: 1,colorSpace: PanoramaEngine.linearSpace)!
        }
        return CIImage(color: color(peak)).cropped(to: CGRect(x: 80,y: 0,width: width,height: 100))
            .composited(over: CIImage(color: color(0.18)).cropped(to: CGRect(x: 0,y: 0,width: 100,height: 100)))
    }
    private func pixels(_ image: CIImage) -> PanoramaRaster { PanoramaRaster(image: image,context: context,width: 100,height: 100) }
    private func pixels(_ plan: PanoramaPlan) throws -> PanoramaRaster { pixels(CIImage(cgImage: try XCTUnwrap(plan.preview))) }

    func testHighlightBrightnessPreservesMidtonesColorAndExposure() throws {
        for width in [1.0,10,20] {
            for ceiling in [1.0,2,4,16] {
                let settings = PanoramaToneSettings(exposureEV: 1,highlightHeadroom: ceiling)
                let result = pixels(PanoramaToneMapping.image(scene(100,width: width),settings: settings,lccProtection: false))
                XCTAssertEqual(try XCTUnwrap(result.rgb(20,20)).x,0.36,accuracy: 0.0002)
                let highlight = try XCTUnwrap(result.rgb(80,20))
                XCTAssertLessThan(highlight.x,ceiling + 0.001)
                XCTAssertGreaterThan(highlight.x,0.9 * ceiling)
                XCTAssertEqual(highlight.y/highlight.x,0.5,accuracy: 0.001)
                XCTAssertEqual(highlight.z/highlight.x,0.2,accuracy: 0.001)
            }
        }
        let neutral = pixels(PanoramaToneMapping.image(scene(),settings: .init(),lccProtection: false))
        XCTAssertEqual(try XCTUnwrap(neutral.rgb(85,20)).x,20,accuracy: 0.01)
    }

    func testCachedAdjustmentIsNonCumulativeAndLCCDoesNotDimWholeImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).png")
        try context.writePNGRepresentation(of: scene(0.9),to: url,format: .RGBA16,colorSpace: PanoramaEngine.linearSpace)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = PanoramaEngine()
        var plan = try engine.singlePhoto(PanoramaSource(url: url))
        plan.previewImages = [scene()]
        plan.lccState = PanoramaLCCState(profileID: UUID(),profileName: "unity",offsetMM: .zero,gainImages: [],usesFixedDecode: [],
            complete: true,coveredFraction: 1,suggestedCropRect: nil,cropRect: nil,footprintRects: [],sensor: .init(width: 36,height: 24,source: "Test"),
            exposureEV: 0,protectHighlights: true,highlightEV: -4)
        // Adjustment must work with only cached pixels, without opening the originals again.
        try FileManager.default.removeItem(at: url)
        let protected = try engine.applyingTone(plan,settings: .panoramaDefault)
        XCTAssertEqual(protected.lccState?.highlightEV,0)
        XCTAssertEqual(try XCTUnwrap(pixels(protected).rgb(20,20)).x,0.18,accuracy: 0.001)
        let brighter = try engine.applyingTone(protected,settings: .init(exposureEV: 1,highlightHeadroom: 2))
        XCTAssertEqual(try XCTUnwrap(pixels(brighter).rgb(20,20)).x,0.36,accuracy: 0.001)
        let reset = try engine.applyingTone(brighter,settings: .panoramaDefault)
        XCTAssertEqual(try XCTUnwrap(pixels(reset).rgb(20,20)).x,0.18,accuracy: 0.001)
        XCTAssertEqual(reset.origins,plan.origins); XCTAssertEqual(reset.ownership,plan.ownership)
        XCTAssertEqual(reset.gains,plan.gains); XCTAssertEqual(reset.blendMasks,plan.blendMasks)
        XCTAssertThrowsError(try engine.applyingTone(plan,settings: .init(exposureEV: .nan)))
        let cancellation = PanoramaCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try engine.applyingTone(plan,settings: .panoramaDefault,cancellation: cancellation))
    }

    func testWorkerExportAndLegacyMetadataUseTheSameToneOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).png")
        try context.writePNGRepresentation(of: scene(0.9),to: url,format: .RGBA16,colorSpace: PanoramaEngine.linearSpace)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = PanoramaEngine(), original = try engine.singlePhoto(PanoramaSource(url: url))
        let plan = try engine.applyingTone(original,settings: .init(exposureEV: 2,highlightHeadroom: 2))
        let snapshot = try PanoramaSnapshot(plan: plan)
        let encoded = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(PanoramaSnapshot.self,from: encoded).plan()
        XCTAssertEqual(restored.tone,plan.tone)
        let exported = pixels(try engine.renderComposite(restored)), preview = try pixels(plan)
        for x in [20.0,85] {
            let a = try XCTUnwrap(exported.rgb(x,20)), b = try XCTUnwrap(preview.rgb(x,20))
            XCTAssertEqual(a.x,b.x,accuracy: 0.004); XCTAssertEqual(a.y,b.y,accuracy: 0.004)
        }
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); legacy.removeValue(forKey: "tone")
        let old = try JSONDecoder().decode(PanoramaSnapshot.self,from: JSONSerialization.data(withJSONObject: legacy)).plan()
        XCTAssertEqual(old.tone,.init())
        let manifest = PanoramaManifest(plan: plan)
        let copy = try JSONDecoder().decode(PanoramaManifest.self,from: JSONEncoder().encode(manifest))
        XCTAssertEqual(copy.tone,plan.tone)
    }

    func testOptionalBostonSixFrameBrightness() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else { throw XCTSkip("External Boston RAWs") }
        let urls = (628...633).map { URL(fileURLWithPath: path).appendingPathComponent(String(format: "B%07d.3FR",$0)) }
        let engine = PanoramaEngine()
        let plan = try engine.analyze(urls: urls) { FileHandle.standardError.write(Data("BOSTON628 \($0)\n".utf8)) }
        func statistics(_ p: PanoramaPlan) throws -> [String: Float] {
            let image = try XCTUnwrap(p.preview)
            let raster = PanoramaRaster(image: CIImage(cgImage: image),context: context,width: 640,height: max(1,640*image.height/image.width))
            let values = stride(from: 0,to: raster.rgba.count,by: 4).compactMap { i -> Float? in
                guard raster.rgba[i+3] > 0.9 else { return nil }
                return max(raster.rgba[i],raster.rgba[i+1],raster.rgba[i+2])
            }.sorted()
            return ["median": values[values.count/2],"p95": values[Int(Double(values.count-1)*0.95)],"p995": values[Int(Double(values.count-1)*0.995)],"maximum": values.last!]
        }
        let start = Date()
        let protected = try engine.applyingTone(plan,settings: .panoramaDefault)
        let brighter = try engine.applyingTone(plan,settings: .init(exposureEV: 1,highlightHeadroom: 2))
        print("BOSTON628 TWO CACHED ADJUSTMENTS",Date().timeIntervalSince(start))
        let before = try statistics(plan), after = try statistics(protected), lifted = try statistics(brighter)
        print("BOSTON628 BRIGHTNESS",before,"DEFAULT",after,"EV+1/HDR2",lifted,"canvas",plan.size)
        XCTAssertEqual(plan.sources.count,6)
        XCTAssertEqual(after["median"]!,before["median"]!,accuracy: 0.001)
        XCTAssertEqual(lifted["median"]!,before["median"]! * 2,accuracy: 0.002)
        XCTAssertLessThan(lifted["maximum"]!,2.01)
        XCTAssertEqual(brighter.origins,plan.origins)
        if let output = ProcessInfo.processInfo.environment["PHOTONS_TONE_OUTPUT"] {
            let dir = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
            try JSONEncoder().encode(["before": before,"default": after,"brighter": lifted]).write(to: dir.appendingPathComponent("brightness.json"))
            for (name,p) in [("before",plan),("default",protected),("brighter",brighter)] {
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(name).png") as CFURL,"public.png" as CFString,1,nil))
                CGImageDestinationAddImage(destination,try XCTUnwrap(p.preview),nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
