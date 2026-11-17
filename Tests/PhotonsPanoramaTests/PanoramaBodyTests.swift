import XCTest
@testable import PhotonsPanorama

final class PanoramaBodyTests:XCTestCase {
    func testCounterclockwiseTravelAndSymmetry() {
        let maxBody=PanoramaCameraBody.alpa12Max
        XCTAssertEqual(maxBody.travel(at:.degrees90),.init(left:25,right:18,up:18,down:18))
        XCTAssertEqual(maxBody.travel(at:.degrees180),.init(left:18,right:18,up:18,down:25))
        XCTAssertEqual(maxBody.travel(at:.degrees270),.init(left:18,right:25,up:18,down:18))
        XCTAssertEqual(PanoramaCameraBody.allCases.map {$0.orientations.count},[4,4,2,2,1])
        XCTAssertEqual(PanoramaCameraBody.alpa12XY.defaultTravel,.init(left:25,right:25,up:45,down:25))
        XCTAssertEqual(PanoramaCameraBody.alpa12STC.travel(at:.degrees90),.init(left:0,right:0,up:18,down:18))
        XCTAssertEqual(PanoramaCameraBody.alpa12Pano.travel(at:.degrees90),.init(left:10,right:10,up:35,down:35))
        XCTAssertEqual(PanoramaCameraBody.alpa12Plus.defaultTravel,.init(left:20,right:20,up:20,down:20))
        // Future asymmetric single-axis bodies must still expose all four placements.
        XCTAssertEqual(PanoramaShiftRange(left:10,right:25,up:0,down:0).distinctOrientations.count,4)
        XCTAssertEqual(PanoramaCameraBody.alpa12STC.canonicalOrientation(.degrees270),.degrees90)
    }
    func testFootprintUsesSensorDirectionIndependentlyAndUnknownOriginIsCentered() {
        let travel=PanoramaCameraBody.alpa12Max.travel(at:.degrees90)
        for sensor in [SensorSize(width:43.8,height:32.9,source:""),SensorSize(width:32.9,height:43.8,source:"")] {
            let known=travel.coverage(sensor:sensor,centered:false),unknown=travel.coverage(sensor:sensor,centered:true)
            XCTAssertEqual(known.width,43+sensor.width,accuracy:1e-9)
            XCTAssertEqual(known.height,36+sensor.height,accuracy:1e-9)
            XCTAssertEqual(known.midX,-3.5,accuracy:1e-9)
            XCTAssertEqual(unknown.midX,0,accuracy:1e-9);XCTAssertEqual(unknown.midY,0,accuracy:1e-9)
            XCTAssertEqual(known.size,unknown.size)
        }
        XCTAssertTrue(travel.contains(CGPoint(x:-25,y:18)))
        XCTAssertFalse(travel.contains(CGPoint(x:18.1,y:0)))
    }
    func testOpticalOriginConstraintsFollowBodyAndOrientation() throws {
        let centers=[CGPoint(x:0,y:-15),CGPoint(x:0,y:15)]
        XCTAssertNil(PanoramaCameraBody.alpa12STC.travel(at:.degrees0).opticalOriginBounds(centers:centers))
        let bounds=try XCTUnwrap(PanoramaCameraBody.alpa12STC.travel(at:.degrees90).opticalOriginBounds(centers:centers,tolerance:0))
        XCTAssertEqual(bounds,CGRect(x:0,y:-3,width:0,height:6))
        let wide=[CGPoint(x:-24,y:-30),CGPoint(x:24,y:30)]
        XCTAssertNil(PanoramaCameraBody.alpa12Max.defaultTravel.opticalOriginBounds(centers:wide))
        let xy=try XCTUnwrap(PanoramaCameraBody.alpa12XY.defaultTravel.opticalOriginBounds(centers:wide,tolerance:0))
        XCTAssertEqual(xy,CGRect(x:-1,y:-15,width:2,height:10))
    }
    func testLCCMatchesRelativeOrientationAndEquivalentPlacements() throws {
        let summary=LCCProfileSummary(LCCProfileTests().sample())
        for orientation in LCCCaptureOrientation.allCases {
            let sensor=SensorSize(width:orientation.isPortrait ? 24:36,height:orientation.isPortrait ? 36:24,source:"")
            let matched=summary.placement(camera:"Test back",exifOrientation:orientation.rawValue,sensor:sensor,
                cameraBody:.alpa12Max,bodyOrientation:orientation.rotation)
            XCTAssertEqual(matched?.variant.orientation,.landscape)
            XCTAssertEqual(matched?.bodyOrientation,orientation.rotation)
        }
        let portrait=SensorSize(width:24,height:36,source:"")
        XCTAssertNil(summary.match(camera:"Test back",exifOrientation:8,sensor:portrait,cameraBody:.alpa12Max))
        XCTAssertNotNil(summary.match(camera:"Test back",exifOrientation:6,sensor:portrait,cameraBody:.alpa12STC,bodyOrientation:.degrees90))
        XCTAssertNotNil(summary.match(camera:"Test back",exifOrientation:3,sensor:.init(width:36,height:24,source:""),cameraBody:.alpa12Pano))
        XCTAssertNotNil(summary.match(camera:"Test back",exifOrientation:8,sensor:portrait,cameraBody:.alpa12Plus))
        XCTAssertNil(summary.match(camera:"Other back",exifOrientation:8,sensor:portrait,cameraBody:.alpa12Plus))
    }
    func testRotatedWhitePlateCreationPreservesNativeMeasurementsAndMetadata() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer {try? FileManager.default.removeItem(at:url)}
        try LCCCameraTests().fixture().dng().data.write(to:url)
        var original=try LCCCreationFrame(url:url);original.shiftConfirmed=true;original.shiftX=7;original.shiftY=3
        let base=try LCCProfileBuilder.create(name:"Test",aperture:11,notes:"",frames:[original],sensorLongEdge:36,sensorShortEdge:24,cameraBody:.alpa12Max)
        for angle in PanoramaBodyOrientation.allCases {
            var rotated=original;rotated.bodyOrientation=angle
            rotated.orientation=LCCCaptureOrientation.allCases.first {$0.rotation==angle}!
            let shift=angle.rotate(CGPoint(x:7,y:3));rotated.shiftX=shift.x;rotated.shiftY=shift.y
            let profile=try LCCProfileBuilder.create(name:"Rotated",aperture:11,notes:"",frames:[rotated],sensorLongEdge:36,sensorShortEdge:24,cameraBody:.alpa12Max)
            XCTAssertEqual(profile.captures[0].grid,base.captures[0].grid)
            XCTAssertEqual(profile.captures[0].orientation,.landscape)
            XCTAssertEqual(profile.captures[0].shiftX,7);XCTAssertEqual(profile.captures[0].shiftY,3)
            XCTAssertEqual(profile.captures[0].bodyOrientation,angle)
            let decoded=try LCCProfileCodec.decode(LCCProfileCodec.encode(profile))
            XCTAssertEqual(decoded,profile);XCTAssertEqual(LCCProfileSummary(decoded).cameraBody,.alpa12Max)
        }
    }
    func testWholeCameraRotationKeepsFourChannelGainsAndCoverage() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        var profile=LCCCameraTests().profile(),values=profile.captures[0].grid.floats
        // Deliberately asymmetric cast: a rotation sign error cannot pass by radial symmetry.
        for i in stride(from:0,to:values.count,by:4) {
            let x=Double((i/4)%64)/64,y=Double((i/4)/64)/48
            for c in 0..<4 {values[i+c] *= Float(exp((0.3+Double(c)*0.2)*x-0.4*y))}
        }
        profile.captures[0].grid.values=LCCMeasurementGrid.pack(values)
        let field=try LCCCorrectionField(profile:profile,orientation:.landscape)
        var expected:[SIMD4<Float>]?
        for orientation in LCCCaptureOrientation.allCases {
            let angle=orientation.rotation,url=dir.appendingPathComponent("\(angle.rawValue).dng")
            try LCCCameraTests().fixture(orientation:orientation.rawValue).dng().data.write(to:url)
            let source=try PanoramaSource(url:url)
            let sensor=SensorSize(width:orientation.isPortrait ? 24:36,height:orientation.isPortrait ? 36:24,source:"")
            let map=LCCCameraGainMap(field:field,source:source,origin:.zero,panoramaSize:source.size,sensor:sensor,
                offset:angle.rotate(CGPoint(x:2,y:-1)),bodyOrientation:angle)
            if let expected {for i in stride(from:0,to:expected.count,by:31) {for c in 0..<4 {XCTAssertEqual(map.values[i][c],expected[i][c],accuracy:0.00001)}}}
            else {expected=map.values}
            let oriented=LCCOrientedField(field:field,bodyOrientation:angle)
            XCTAssertTrue(oriented.region.covers(angle.rotate(CGRect(x:-10,y:-8,width:20,height:16))))
            XCTAssertFalse(oriented.region.covers(angle.rotate(CGRect(x:-40,y:-8,width:20,height:16))))
        }
    }
    func testPositionSolverFitsRotatedFieldInImageCoordinates() throws {
        let field=try LCCCorrectionField(profile:LCCCameraTests().profile(),orientation:.landscape)
        for angle in PanoramaBodyOrientation.allCases {
            let oriented=LCCOrientedField(field:field,bodyOrientation:angle),truth=CGPoint(x:2.2,y:-1.6)
            var observations:[LCCPositionSolver.Observation]=[]
            for y in stride(from:-7.0,through:7.0,by:2) {for x in stride(from:-7.0,through:7.0,by:2) {
                let point=CGPoint(x:x,y:y),g=try XCTUnwrap(oriented.gain(at:CGPoint(x:x-truth.x,y:y-truth.y)))
                observations.append(.init(frame:0,point:point,logRGB:SIMD3(-log(g.x),-log(g.y),-log(g.z)),field:oriented))
            }}
            let result=try LCCPositionSolver.search(observations:observations,xRange:-4...4,yRange:-4...4,flat:true,cancellation:.init())
            XCTAssertEqual(result.point.x,truth.x,accuracy:0.2);XCTAssertEqual(result.point.y,truth.y,accuracy:0.2)
        }
    }
}
