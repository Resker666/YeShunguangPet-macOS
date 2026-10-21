import XCTest
@testable import PetCore

final class SpeechTests:XCTestCase {
    func testLegacyDefaultsHaveCooldownAndEmptySpeechDoesNotFallBackOrConsumeCooldown() {
        var policy=SpeechPolicy(random:{0})
        XCTAssertNotNil(policy.select(lines:nil,event:.click,at:.zero))
        XCTAssertNil(policy.select(lines:nil,event:.drag,at:.milliseconds(29999)))
        XCTAssertNotNil(policy.select(lines:nil,event:.drag,at:.seconds(30)))
        var empty=SpeechPolicy(random:{0})
        XCTAssertNil(empty.select(lines:.init(click:[],drag:[],focusCompleted:[],breakCompleted:[]),event:.click,at:.zero))
        XCTAssertNotNil(empty.select(lines:nil,event:.click,at:.seconds(1)))
    }
    func testSkinLinesTakePrecedenceAndAlternativesAvoidImmediateRepeats() {
        let lines=SpeechLines(click:["甲","乙"],drag:["丙"],focusCompleted:[],breakCompleted:[])
        var policy=SpeechPolicy(random:{0})
        XCTAssertEqual(policy.select(lines:lines,event:.click,at:.zero),"甲")
        XCTAssertEqual(policy.select(lines:lines,event:.click,at:.seconds(30)),"乙")
        XCTAssertEqual(policy.select(lines:lines,event:.click,at:.seconds(60)),"甲")
        XCTAssertEqual(policy.select(lines:lines,event:.drag,at:.seconds(90)),"丙")
    }
    func testSpeechPlacementUsesAboveThenBelowInLogicalCoordinates() {
        let area=CGRect(x:0,y:0,width:800,height:800),size=CGSize(width:100,height:50)
        XCTAssertEqual(SpeechPlacement.place(anchor:CGRect(x:100,y:100,width:32,height:32),size:size,area:area),CGRect(x:66,y:140,width:100,height:50))
        XCTAssertEqual(SpeechPlacement.place(anchor:CGRect(x:100,y:750,width:32,height:32),size:size,area:area),CGRect(x:66,y:692,width:100,height:50))
        XCTAssertEqual(SpeechPlacement.place(anchor:CGRect(x:-300,y:200,width:32,height:32),size:size,area:CGRect(x:-1000,y:-100,width:800,height:700)),CGRect(x:-334,y:240,width:100,height:50))
    }
    func testSpeechPlacementClampsEdgesUsesSidesAndRejectsNoSpace() {
        XCTAssertEqual(SpeechPlacement.place(anchor:CGRect(x:0,y:0,width:32,height:32),size:CGSize(width:100,height:50),area:CGRect(x:0,y:0,width:800,height:800)),CGRect(x:0,y:40,width:100,height:50))
        XCTAssertEqual(SpeechPlacement.place(anchor:CGRect(x:100,y:24,width:32,height:32),size:CGSize(width:100,height:50),area:CGRect(x:0,y:0,width:500,height:80)),CGRect(x:140,y:15,width:100,height:50))
        XCTAssertNil(SpeechPlacement.place(anchor:CGRect(x:0,y:0,width:32,height:32),size:CGSize(width:100,height:50),area:CGRect(x:0,y:0,width:80,height:80)))
        XCTAssertNil(SpeechPlacement.place(anchor:CGRect(x:0,y:0,width:32,height:32),size:.zero,area:CGRect(x:0,y:0,width:800,height:800)))
    }
}
