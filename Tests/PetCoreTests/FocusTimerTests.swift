import XCTest
@testable import PetCore

final class FocusTimerTests:XCTestCase {
    func testManualPhasesPauseLateCompletionAndStaleCommands()throws {
        var timer=FocusTimer();try timer.configure(focusMinutes:1,breakMinutes:1)
        XCTAssertNil(timer.startOrResume(at:.zero));XCTAssertEqual(timer.status,.running)
        XCTAssertNil(timer.pause(at:.seconds(59)));XCTAssertEqual(timer.remaining(at:.seconds(99)),.seconds(1))
        XCTAssertNil(timer.startOrResume(at:.seconds(100)))
        XCTAssertNil(timer.advance(at:.milliseconds(100999)))
        XCTAssertEqual(timer.advance(at:.seconds(101)),.focus);XCTAssertEqual(timer.status,.completed)
        XCTAssertNil(timer.advance(at:.seconds(1000)));XCTAssertNil(timer.deadline)
        XCTAssertNil(timer.startOrResume(at:.seconds(1000)));XCTAssertEqual(timer.phase,.rest)
        XCTAssertEqual(timer.advance(at:.seconds(1060)),.rest);XCTAssertNil(timer.advance(at:.seconds(2000)))
        timer.reset();XCTAssertEqual(timer.phase,.focus);XCTAssertEqual(timer.status,.ready)
        XCTAssertEqual(timer.remaining(at:.seconds(2000)),.seconds(60));XCTAssertNil(timer.deadline)
    }
    func testExpiredPauseAndOldStartSettleOnlyOriginalPhase()throws {
        for pause in [true,false] {
            var timer=FocusTimer();try timer.configure(focusMinutes:1,breakMinutes:1)
            _=timer.startOrResume(at:.zero)
            let completed=pause ? timer.pause(at:.seconds(60)) : timer.startOrResume(at:.seconds(60))
            XCTAssertEqual(completed,.focus);XCTAssertEqual(timer.phase,.focus);XCTAssertEqual(timer.status,.completed)
            XCTAssertNil(timer.deadline);XCTAssertNil(timer.advance(at:.seconds(61)))
        }
    }
    func testResetAndInvalidDurationsDoNotCorruptTimer()throws {
        var timer=FocusTimer()
        for values in [(0,5),(121,5),(25,0),(25,61)] {XCTAssertThrowsError(try timer.configure(focusMinutes:values.0,breakMinutes:values.1))}
        XCTAssertEqual(timer.remaining(at:.zero),.seconds(1500))
        _=timer.startOrResume(at:.zero)
        XCTAssertThrowsError(try timer.configure(focusMinutes:1,breakMinutes:1))
        timer.reset();XCTAssertNil(timer.advance(at:.seconds(10000)));XCTAssertEqual(timer.status,.ready)
    }
    func testLateWakeHasOneCompletionAndPausedTimeDoesNotElapse()throws {
        var timer=FocusTimer();_=timer.startOrResume(at:.zero)
        XCTAssertEqual(timer.advance(at:.seconds(86400)),.focus);XCTAssertNil(timer.advance(at:.seconds(86400)))
        _=timer.startOrResume(at:.seconds(86400));_=timer.pause(at:.seconds(86410))
        XCTAssertEqual(timer.remaining(at:.seconds(999999)),.seconds(290));XCTAssertNil(timer.advance(at:.seconds(999999)))
    }
}
