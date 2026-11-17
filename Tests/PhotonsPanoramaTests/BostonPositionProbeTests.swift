import XCTest
@testable import PhotonsPanorama

final class BostonPositionProbeTests:XCTestCase {
    func testIndependentBostonPositions() throws {
        guard let folder=ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else {throw XCTSkip("External Boston RAWs")}
        let store=LCCProfileStore();try store.installBundledProfile()
        let profile=try store.load(LCCLensProfile.builtInID)
        var fields:[LCCCaptureOrientation:LCCCorrectionField]=[:]
        for orientation in Set(profile.captures.map(\.orientation)) {fields[orientation]=try LCCCorrectionField(profile:profile,orientation:orientation)}
        var rows:[[String:Any]]=[]
        for name in ["B0000659.3FR","B0000660.3FR","B0000661.3FR","B0000662.3FR"] {
            try autoreleasepool {
                let source=try PanoramaSource(url:URL(fileURLWithPath:folder).appendingPathComponent(name))
                let engine=PanoramaEngine(),sensor=try XCTUnwrap(source.sensor)
                let plan=try engine.prepareLCCImages(engine.singlePhoto(source))
                let result=try LCCPositionSolver.solve(plan:plan,fields:fields,sensor:sensor,allowPairedFlats:false)
                rows.append(["file":name,"shiftX":-result.offsetMM.x,"shiftY":-result.offsetMM.y,"residual":result.residual,"requiresManualSeed":result.requiresManualSeed])
            }
        }
        let output=URL(fileURLWithPath:"/tmp/photons-boston-single-position.json")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print(String(data:try Data(contentsOf:output),encoding:.utf8)!)
    }
}
