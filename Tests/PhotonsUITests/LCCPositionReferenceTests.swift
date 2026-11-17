import XCTest
import CoreImage
import PhotonsPanorama
@testable import PhotonsUI

@MainActor
final class LCCPositionReferenceTests:XCTestCase {
    func testSwitchingFrameAndCroppedPictureCenterPreservesManualPlacement() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("lcc-reference-\(UUID().uuidString).tiff")
        defer {try? FileManager.default.removeItem(at:url)}
        try CIContext().writeTIFFRepresentation(of:CIImage(color:.gray).cropped(to:CGRect(x:0,y:0,width:36,height:24)),
            to:url,format:.RGBA16,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        var manifest=PanoramaManifest(plan:try PanoramaEngine().singlePhoto(PanoramaSource(url:url)),sensor:.init(width:36,height:24,source:"test"))
        manifest.crop=CGRect(x:0.1,y:0.3,width:0.6,height:0.6)
        let model=LCCWindowModel(urls:[])
        model.manifests=[0:manifest];model.resolvedOffset=CGPoint(x:-3,y:7)
        model.shiftX=99;model.shiftY=99 // Stale pre-solve controls must not move the estimate.
        model.setPositionConfirmed(true)
        XCTAssertEqual(model.resolvedOffset,CGPoint(x:-3,y:7))
        model.correctedManifest=manifest
        model.selectPictureCenter(true)
        XCTAssertNotNil(model.correctedManifest,"Selecting a different reference must retain the valid preview")
        XCTAssertEqual(model.shiftX,-0.6,accuracy:1e-10);XCTAssertEqual(model.shiftY,-9.4,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(model.resolvedOffset).x,-3,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(model.resolvedOffset).y,7,accuracy:1e-10)
        model.shiftY += 2;model.invalidateCorrection()
        XCTAssertEqual(try XCTUnwrap(model.resolvedOffset).y,5,accuracy:1e-10)
        model.selectReference(0)
        XCTAssertFalse(model.usePictureCenter)
        XCTAssertEqual(model.shiftX,3,accuracy:1e-10);XCTAssertEqual(model.shiftY,-5,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(model.resolvedOffset).y,5,accuracy:1e-10)
    }
}
