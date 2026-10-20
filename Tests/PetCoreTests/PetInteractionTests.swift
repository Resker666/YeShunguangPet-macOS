import XCTest
import CoreGraphics
@testable import PetCore

final class PetInteractionTests: XCTestCase {
    func testSingleAndDoubleClickAndCancel() {
        var now=Duration.zero; let p=PetInteraction(doubleClickInterval:.milliseconds(500),now:{now})
        p.pointerDown(at:.zero,clickCount:1); XCTAssertTrue(p.pointerUp(at:.zero).isEmpty)
        now = .milliseconds(499); XCTAssertTrue(p.expireClick().isEmpty)
        now = .milliseconds(500); XCTAssertEqual(p.expireClick(),[.play(.waving)]); XCTAssertTrue(p.expireClick().isEmpty)
        p.pointerDown(at:.zero,clickCount:1); _=p.pointerUp(at:.zero)
        p.pointerDown(at:.zero,clickCount:2); XCTAssertEqual(p.pointerUp(at:.zero),[.play(.jumping)])
        now += .seconds(1); XCTAssertTrue(p.expireClick().isEmpty)
        p.pointerDown(at:.zero,clickCount:1); _=p.pointerUp(at:.zero); p.cancel(); now += .seconds(1); XCTAssertTrue(p.expireClick().isEmpty)
    }
    func testSecondPressBecomesDragAndNeverClicks() {
        var now=Duration.zero; let p=PetInteraction(doubleClickInterval:.milliseconds(500),now:{now})
        p.pointerDown(at:.zero,clickCount:1); _=p.pointerUp(at:.zero); now = .milliseconds(100)
        p.pointerDown(at:.zero,clickCount:2)
        XCTAssertTrue(p.pointerMoved(to:CGPoint(x:4,y:0)).isEmpty)
        XCTAssertEqual(p.pointerMoved(to:CGPoint(x:5,y:0)),[.beginDrag,.drag(delta:CGSize(width:5,height:0))])
        XCTAssertEqual(p.pointerUp(at:CGPoint(x:5,y:0)),[.finishDrag])
        now = .seconds(1); XCTAssertTrue(p.expireClick().isEmpty)
    }
    func testFallbackAndRuntimeGate() throws {
        let m=try ManifestDecoder.decode(SkinFixtures.minimalManifest)
        XCTAssertEqual(m.resolve(.jumping),.idle); XCTAssertEqual(m.resolve(.runningLeft),.idle)
        var gate=RuntimeGate(); gate.loaded=true; gate.visible=true; XCTAssertTrue(gate.shouldRunFrames)
        gate.visible=false; gate.sleeping=true; gate.sleeping=false; XCTAssertFalse(gate.shouldRunFrames)
        gate.visible=true; gate.exiting=true; XCTAssertFalse(gate.shouldRunFrames)
    }
}
