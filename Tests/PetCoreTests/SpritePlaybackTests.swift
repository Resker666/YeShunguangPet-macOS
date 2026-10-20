import XCTest
@testable import PetCore

final class SpritePlaybackTests: XCTestCase {
    func testUnequalFrameBoundaryAndLongDelay() {
        var now=Duration.zero
        var p=SpritePlayback(now:{now})
        XCTAssertTrue(p.sample().completed)
        p.start(.init(durationsMs:[300,200],loop:true))
        XCTAssertEqual(p.sample().index,0)
        now = .milliseconds(300); XCTAssertEqual(p.sample().index,1); XCTAssertEqual(p.sample().untilNextFrame,.milliseconds(200))
        now = .milliseconds(500); XCTAssertEqual(p.sample().index,0)
        now = .seconds(3600) + .milliseconds(450); XCTAssertEqual(p.sample().index,1)
    }
    func testPauseResumePreservesRemainingAndIsIdempotent() {
        var now=Duration.zero; var p=SpritePlayback(now:{now})
        p.start(.init(durationsMs:[300,200],loop:true)); now = .milliseconds(100); p.pause(); p.pause()
        now = .seconds(3600); XCTAssertEqual(p.sample().index,0); XCTAssertNil(p.sample().untilNextFrame)
        p.resume(); p.resume(); XCTAssertEqual(p.sample().untilNextFrame,.milliseconds(200))
        now += .milliseconds(200); XCTAssertEqual(p.sample().index,1)
    }
    func testOneShotCompletesAndRestartResets() {
        var now=Duration.zero; var p=SpritePlayback(now:{now}); let action=AnimationDefinition(durationsMs:[100,200])
        p.start(action); now = .milliseconds(300); XCTAssertTrue(p.sample().completed); XCTAssertEqual(p.sample().index,1); XCTAssertNil(p.sample().untilNextFrame)
        p.start(action); XCTAssertEqual(p.sample().index,0); XCTAssertFalse(p.sample().completed)
        now = .zero; XCTAssertEqual(p.sample().index,0)
    }
}
