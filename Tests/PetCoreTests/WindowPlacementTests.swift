import XCTest
import CoreGraphics
@testable import PetCore

final class WindowPlacementTests: XCTestCase {
    let size=CGSize(width:192,height:208)
    let screen=ScreenArea(id:"main",visibleFrame:CGRect(x:0,y:40,width:1000,height:700),isPrimary:true)
    func testRecallUsesVisibleFrameAndTwentyFourPointMargin() {
        XCTAssertEqual(WindowPlacement.recall(size:size,screens:[screen])?.origin,CGPoint(x:784,y:64))
        XCTAssertNil(WindowPlacement.recall(size:size,screens:[]))
    }
    func testRestoresAndClampsNegativeScreenCoordinates() {
        let left=ScreenArea(id:"left",visibleFrame:CGRect(x:-1000,y:0,width:1000,height:700),isPrimary:false)
        let saved=PlacementSnapshot(screenID:"left",origin:CGPoint(x:-1200,y:900),visibleFrame:left.visibleFrame)
        XCTAssertEqual(WindowPlacement.restore(saved,size:size,screens:[screen,left])?.origin,CGPoint(x:-1000,y:492))
        XCTAssertEqual(WindowPlacement.restore(saved,size:size,screens:[screen])?.origin,CGPoint(x:784,y:64))
    }
    func testDisplayResizeMapsMovableDistanceAndOversizeStaysVisible() {
        let old=PlacementSnapshot(screenID:"main",origin:CGPoint(x:404,y:286),visibleFrame:screen.visibleFrame)
        let changed=ScreenArea(id:"main",visibleFrame:CGRect(x:100,y:100,width:600,height:500),isPrimary:true)
        XCTAssertEqual(WindowPlacement.restore(old,size:size,screens:[changed])?.origin,CGPoint(x:304,y:246))
        let tiny=ScreenArea(id:"main",visibleFrame:CGRect(x:-10,y:20,width:100,height:100),isPrimary:true)
        XCTAssertEqual(WindowPlacement.restore(old,size:size,screens:[tiny])?.origin,CGPoint(x:-10,y:20))
    }
    func testCaptureChoosesMostIntersectionAndRejectsInvalidGeometry() {
        let left=ScreenArea(id:"left",visibleFrame:CGRect(x:-1000,y:0,width:1000,height:700),isPrimary:false)
        XCTAssertEqual(WindowPlacement.capture(origin:CGPoint(x:-100,y:100),size:size,screens:[screen,left])?.screenID,"left")
        XCTAssertNil(WindowPlacement.capture(origin:CGPoint(x:Double.nan,y:0),size:size,screens:[screen]))
        XCTAssertNil(WindowPlacement.restore(nil,size:.zero,screens:[screen]))
    }
}
