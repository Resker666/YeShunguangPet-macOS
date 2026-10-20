import AppKit
import XCTest

@MainActor final class FrameSchedulerTests: XCTestCase {
    func testReplacingAndCancellingOnlyFiresLatest() {
        let clock=ContinuousClock(); let origin=clock.now
        var fires=0
        let scheduler=FrameScheduler(now:{origin.duration(to:clock.now)},onFire:{fires += 1})
        scheduler.schedule(after:.milliseconds(5)); scheduler.cancel()
        scheduler.schedule(after:.milliseconds(10)); scheduler.schedule(after:.milliseconds(15))
        XCTAssertEqual(scheduler.pendingCount,1)
        let until=Date().addingTimeInterval(0.15)
        while Date()<until { RunLoop.main.run(until:Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(fires,1); XCTAssertEqual(scheduler.pendingCount,0)
        scheduler.cancel()
    }
}
