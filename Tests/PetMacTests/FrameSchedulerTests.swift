import AppKit
import XCTest

@MainActor final class FrameSchedulerTests: XCTestCase {
    func testReplacingAndCancellingOnlyFiresLatest() async {
        let clock=ContinuousClock(); let origin=clock.now
        var fires=0
        let fired=expectation(description:"latest scheduled callback fired")
        let scheduler=FrameScheduler(now:{origin.duration(to:clock.now)},onFire:{fires += 1;fired.fulfill()})
        scheduler.schedule(after:.milliseconds(5)); scheduler.cancel()
        scheduler.schedule(after:.milliseconds(10)); scheduler.schedule(after:.milliseconds(15))
        XCTAssertEqual(scheduler.pendingCount,1)
        await fulfillment(of:[fired],timeout:3)
        XCTAssertEqual(fires,1); XCTAssertEqual(scheduler.pendingCount,0)
        scheduler.cancel()
    }
}
