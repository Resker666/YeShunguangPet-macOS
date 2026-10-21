import XCTest
@testable import PetCore

final class PetRoamingTests: XCTestCase {
    private let area=CGRect(x:0,y:0,width:1000,height:700)
    private func frame(_ x: CGFloat = 100) -> CGRect { CGRect(x:x,y:100,width:32,height:32) }
    func testDisabledNeverSchedulesOrReadsPointer() {
        var motion=PetRoaming(random:{0.5})
        motion.update(enabled:false,intervalSeconds:75,available:true,at:.zero)
        XCTAssertNil(motion.nextDeadline)
        XCTAssertNil(motion.step(at:.seconds(100),frame:frame(),area:area,cursorNear:{XCTFail("disabled read");return false}))
    }
    func testWaitThenShortRightWalkCompletesAndSchedulesFreshInterval() throws {
        var motion=PetRoaming(random:{0.5})
        motion.update(enabled:true,intervalSeconds:75,available:true,at:.zero)
        XCTAssertEqual(motion.nextDeadline,.seconds(75))
        XCTAssertNil(motion.step(at:.seconds(74),frame:frame(),area:area,cursorNear:{XCTFail("early read");return false}))
        let first=try XCTUnwrap(motion.step(at:.seconds(75),frame:frame(),area:area,cursorNear:{false}))
        XCTAssertEqual(first.x,100);XCTAssertEqual(first.direction,1);XCTAssertTrue(motion.isWalking)
        var x:CGFloat=100
        for i in 1...23 {
            let step=try XCTUnwrap(motion.step(at:.seconds(75) + .milliseconds(i*100),frame:frame(x),area:area,cursorNear:{false}))
            x=step.x
        }
        XCTAssertEqual(x,190,accuracy:0.0001);XCTAssertFalse(motion.isWalking)
        XCTAssertEqual(motion.nextDeadline,.milliseconds(152300))
    }
    func testNearPointerDefersStartAndPausesWithoutLaterTeleport() throws {
        var motion=PetRoaming(random:{0.5})
        motion.update(enabled:true,intervalSeconds:75,available:true,at:.zero)
        XCTAssertNil(motion.step(at:.seconds(75),frame:frame(),area:area,cursorNear:{true}))
        XCTAssertEqual(motion.nextDeadline,.milliseconds(75500))
        _=motion.step(at:.milliseconds(75500),frame:frame(),area:area,cursorNear:{false})
        let paused=try XCTUnwrap(motion.step(at:.milliseconds(75600),frame:frame(),area:area,cursorNear:{true}))
        XCTAssertEqual(paused.x,100);XCTAssertTrue(paused.isPaused)
        _=motion.step(at:.seconds(500),frame:frame(),area:area,cursorNear:{true})
        let resumed=try XCTUnwrap(motion.step(at:.milliseconds(500100),frame:frame(),area:area,cursorNear:{false}))
        XCTAssertEqual(resumed.x,104,accuracy:0.0001);XCTAssertFalse(resumed.isPaused)
    }
    func testLateTickMovesAtMostFourPointsWithoutCatchUp() throws {
        var motion=PetRoaming(random:{0.5});motion.update(enabled:true,intervalSeconds:75,available:true,at:.zero)
        _=motion.step(at:.seconds(75),frame:frame(),area:area,cursorNear:{false})
        let step=try XCTUnwrap(motion.step(at:.seconds(3600),frame:frame(),area:area,cursorNear:{false}))
        XCTAssertEqual(step.x,104,accuracy:0.0001);XCTAssertFalse(step.isFinished)
    }
    func testNegativeScreenEdgeChoosesInwardAndStopsBeforeBoundary() throws {
        let area=CGRect(x:-200,y:-100,width:180,height:120)
        var motion=PetRoaming(random:{0});motion.update(enabled:true,intervalSeconds:20,available:true,at:.zero)
        var frame=CGRect(x:-52,y:-50,width:32,height:32)
        let first=try XCTUnwrap(motion.step(at:.seconds(15),frame:frame,area:area,cursorNear:{false}))
        XCTAssertEqual(first.direction,-1)
        for i in 1...15 { frame.origin.x=try XCTUnwrap(motion.step(at:.seconds(15) + .milliseconds(i*100),frame:frame,area:area,cursorNear:{false})).x }
        XCTAssertEqual(frame.minX,-112,accuracy:0.0001);XCTAssertFalse(motion.isWalking)
        XCTAssertEqual(frame.minY,-50)
    }
    func testTinyOrInvalidAreaDoesNotPollPointerOrSpin() {
        for area in [CGRect(x:100,y:100,width:40,height:40),CGRect(x:100,y:100,width:100,height:20),CGRect.zero] {
            var motion=PetRoaming(random:{0});motion.update(enabled:true,intervalSeconds:20,available:true,at:.zero)
            XCTAssertNil(motion.step(at:.seconds(15),frame:frame(),area:area,cursorNear:{XCTFail("no space");return false}))
            XCTAssertFalse(motion.isWalking);XCTAssertEqual(motion.nextDeadline,.seconds(30))
        }
    }
    func testSuppressionPreservesWaitAndCancellationDoesNotResumeOldPath() {
        var motion=PetRoaming(random:{0.5});motion.update(enabled:true,intervalSeconds:75,available:true,at:.zero)
        motion.update(enabled:true,intervalSeconds:75,available:false,at:.seconds(10));XCTAssertNil(motion.nextDeadline)
        motion.update(enabled:true,intervalSeconds:75,available:true,at:.seconds(100));XCTAssertEqual(motion.nextDeadline,.seconds(165))
        _=motion.step(at:.seconds(165),frame:frame(),area:area,cursorNear:{false})
        motion.cancel(at:.seconds(166));XCTAssertFalse(motion.isWalking);XCTAssertEqual(motion.nextDeadline,.seconds(241))
        motion.update(enabled:false,intervalSeconds:75,available:true,at:.seconds(167));XCTAssertNil(motion.nextDeadline)
    }
    func testGeometryChangeEndsCurrentPath() throws {
        var motion=PetRoaming(random:{0.5});motion.update(enabled:true,intervalSeconds:75,available:true,at:.zero)
        _=motion.step(at:.seconds(75),frame:frame(),area:area,cursorNear:{false})
        let step=try XCTUnwrap(motion.step(at:.milliseconds(75100),frame:frame(),area:CGRect(x:0,y:0,width:900,height:700),cursorNear:{false}))
        XCTAssertTrue(step.isFinished);XCTAssertFalse(motion.isWalking);XCTAssertEqual(step.x,100)
    }
    func testWindowPixelRoundingDoesNotAccumulateIntoWalkingSpeed() throws {
        var motion=PetRoaming(random:{0.5});motion.update(enabled:true,intervalSeconds:75,available:true,at:.zero)
        _=motion.step(at:.seconds(75),frame:frame(),area:area,cursorNear:{false})
        let first=try XCTUnwrap(motion.step(at:.milliseconds(75033),frame:frame(),area:area,cursorNear:{false}))
        XCTAssertEqual(first.x,101.32,accuracy:0.0001)
        let second=try XCTUnwrap(motion.step(at:.milliseconds(75066),frame:frame(101),area:area,cursorNear:{false}))
        XCTAssertEqual(second.x,102.64,accuracy:0.0001)
        let third=try XCTUnwrap(motion.step(at:.milliseconds(75099),frame:frame(103),area:area,cursorNear:{false}))
        XCTAssertEqual(third.x,103.96,accuracy:0.0001)
    }
}
