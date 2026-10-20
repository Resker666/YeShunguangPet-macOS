import XCTest
import CoreGraphics
@testable import PetCore

final class MouseGazeTests: XCTestCase {
    let bounds=CGRect(x:-116,y:-216,width:32,height:32) // center (-100, -200)
    func testSixteenDirectionsStartUpAndTurnClockwiseInAppKitCoordinates() {
        let offsets:[(Double,Double,Int)]=[(0,100,0),(41.421356,100,1),(100,100,2),(100,41.421356,3),(100,0,4),(100,-41.421356,5),(100,-100,6),(41.421356,-100,7),(0,-100,8),(-41.421356,-100,9),(-100,-100,10),(-100,-41.421356,11),(-100,0,12),(-100,41.421356,13),(-100,100,14),(-41.421356,100,15)]
        for (dx,dy,want) in offsets {
            XCTAssertEqual(MouseGaze.direction(pointer:CGPoint(x:-100+dx,y:-200+dy),bounds:bounds),want)
        }
    }
    func testRadiusDeadZoneAndInvalidGeometryReturnToIdle() {
        for (x,want) in [(41.99,nil),(42,4),(520,4),(520.01,nil)] as [(Double,Int?)] {
            XCTAssertEqual(MouseGaze.direction(pointer:CGPoint(x:-100+x,y:-200),bounds:bounds),want)
        }
        XCTAssertNil(MouseGaze.direction(pointer:CGPoint(x:Double.nan,y:0),bounds:bounds))
        XCTAssertNil(MouseGaze.direction(pointer:.zero,bounds:.zero))
        XCTAssertNil(MouseGaze.direction(pointer:.zero,bounds:CGRect(x:Double.infinity,y:0,width:32,height:32)))
    }
    func testDirectionUsesScaledWindowCenterAndWrapsNearNorth() {
        XCTAssertEqual(MouseGaze.direction(pointer:CGPoint(x:100,y:300),bounds:CGRect(x:4,y:-4,width:192,height:208)),0)
        XCTAssertEqual(MouseGaze.direction(pointer:CGPoint(x:100,y:300),bounds:CGRect(x:4,y:-4,width:384,height:416)),14)
        XCTAssertEqual(MouseGaze.direction(pointer:CGPoint(x:-101,y:-100),bounds:bounds),0)
    }
    func testTwoSecondEncounterEndsEvenWhenPointerMovesAndRearmsOnlyAfterLeaving() {
        var gaze=MouseGaze()
        XCTAssertEqual(gaze.sample(pointer:CGPoint(x:-100,y:-100),bounds:bounds,at:.zero),0)
        XCTAssertEqual(gaze.sample(pointer:CGPoint(x:0,y:-200),bounds:bounds,at:.seconds(1)),4)
        XCTAssertNil(gaze.sample(pointer:CGPoint(x:0,y:-200),bounds:bounds,at:.seconds(2)))
        XCTAssertNil(gaze.sample(pointer:CGPoint(x:-200,y:-200),bounds:bounds,at:.seconds(20)))
        XCTAssertNil(gaze.sample(pointer:CGPoint(x:600,y:-200),bounds:bounds,at:.seconds(21)))
        XCTAssertEqual(gaze.sample(pointer:CGPoint(x:-200,y:-200),bounds:bounds,at:.seconds(22)),12)
    }
    func testResetCancelsOldEncounterAndAllowsFreshShortLook() {
        var gaze=MouseGaze()
        _=gaze.sample(pointer:CGPoint(x:0,y:-200),bounds:bounds,at:.zero)
        gaze.reset(); XCTAssertNil(gaze.direction)
        XCTAssertEqual(gaze.sample(pointer:CGPoint(x:0,y:-200),bounds:bounds,at:.seconds(10)),4)
        XCTAssertNil(gaze.sample(pointer:CGPoint(x:-100,y:-200),bounds:bounds,at:.seconds(11)))
        XCTAssertNil(gaze.direction)
    }
}
