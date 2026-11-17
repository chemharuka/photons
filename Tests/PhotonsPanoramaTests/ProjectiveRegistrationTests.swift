import XCTest
@testable import PhotonsPanorama

final class ProjectiveRegistrationTests:XCTestCase {
    func testRecoversTiltWithOutliersAndRoundTripsCoordinates() throws {
        let expected=PanoramaTransform([1.02,0.008,31,-0.006,1.015,270,0.00003,-0.00002,1])
        var pairs:[ProjectiveRegistration.Pair]=[]
        for y in stride(from:60,through:700,by:80) {for x in stride(from:40,through:900,by:90) {
            let p=CGPoint(x:x,y:y),q=expected.point(p)
            pairs.append(.init(a:CGPoint(x:q.x+sin(Double(x+y))*0.05,y:q.y+cos(Double(x-y))*0.05),b:p))
        }}
        for i in 0..<40 {pairs.append(.init(a:CGPoint(x:(i*317)%1000,y:(i*113)%800),b:CGPoint(x:(i*73)%1000,y:(i*241)%800)))}
        let match=try XCTUnwrap(ProjectiveRegistration.robust(pairs,width:1000,height:800))
        XCTAssertGreaterThan(match.pairs.count,70)
        for p in [CGPoint(x:100,y:100),CGPoint(x:700,y:600)] {
            let a=match.transform.point(p),b=expected.point(p)
            XCTAssertLessThan(hypot(a.x-b.x,a.y-b.y),0.2)
            let restored=try XCTUnwrap(match.transform.inverse).point(a)
            XCTAssertEqual(restored.x,p.x,accuracy:0.000001)
            XCTAssertEqual(restored.y,p.y,accuracy:0.000001)
        }
    }
    func testRejectsCollinearOrUnrelatedMatches() throws {
        let line=(0..<30).map {i in ProjectiveRegistration.Pair(a:CGPoint(x:i*10,y:10),b:CGPoint(x:i*10,y:20))}
        XCTAssertNil(try ProjectiveRegistration.robust(line,width:1000,height:800))
        var unrelated:[ProjectiveRegistration.Pair]=[]
        for i in 0..<100 {
            let a=CGPoint(x:Double((i*317)%997),y:Double((i*113)%797))
            let b=CGPoint(x:Double((i*73)%991),y:Double((i*241)%787))
            unrelated.append(.init(a:a,b:b))
        }
        XCTAssertNil(try ProjectiveRegistration.robust(unrelated,width:1000,height:800))
    }
}
