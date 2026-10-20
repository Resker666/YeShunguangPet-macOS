import XCTest
@testable import PetCore

final class AutomaticActionsTests: XCTestCase {
    private func manifest(behavior: Any? = nil, actions: [String] = ["waving","jumping"]) throws -> PetManifest {
        var animations:[String:Any]=["idle":["durationsMs":[300],"loop":true]]
        for action in actions { animations[action]=["durationsMs":[100],"loop":false] }
        var fields:[String:Any]=["animations":animations]
        if let behavior { fields["behavior"]=behavior }
        return try ManifestDecoder.decode(SkinFixtures.manifest(fields))
    }
    private func rules(_ values: [[String:Any]]) -> [String:Any] { ["rules":values] }
    func testDisabledMissingAndExplicitEmptyCandidatesNeverScheduleOrReadPointer() throws {
        let variants=[try manifest(),try manifest(actions:[]),try manifest(behavior:rules([]))]
        for (index,manifest) in variants.enumerated() {
            var policy=AutomaticActions(manifest:manifest,random:{0})
            policy.update(enabled:index != 0,intervalSeconds:60,available:true,at:.zero)
            XCTAssertNil(policy.nextDeadline)
            XCTAssertNil(policy.takeAction(at:.seconds(500),cursorNear:{ XCTFail("unnecessary pointer read"); return true }))
        }
    }
    func testLegacyFallbackWaitsRandomizedIntervalAndNeverCatchesUp() throws {
        var policy=AutomaticActions(manifest:try manifest(),random:{0})
        policy.update(enabled:true,intervalSeconds:60,available:true,at:.zero)
        XCTAssertEqual(policy.nextDeadline,.seconds(45))
        XCTAssertNil(policy.takeAction(at:.seconds(44),cursorNear:{false}))
        XCTAssertEqual(policy.takeAction(at:.seconds(45),cursorNear:{ XCTFail("fallback needs no pointer"); return false }),.waving)
        XCTAssertEqual(policy.nextDeadline,.seconds(90))
        XCTAssertEqual(policy.takeAction(at:.seconds(500),cursorNear:{false}),.waving)
        XCTAssertEqual(policy.nextDeadline,.seconds(545))
        XCTAssertNil(policy.takeAction(at:.seconds(500),cursorNear:{false}))
    }
    func testWeightsSelectAcrossExactBoundaryAndOnlyAvailableFallbackIsUsed() throws {
        let custom=try manifest(behavior:rules([["action":"waving","weight":3],["action":"jumping","weight":1]]))
        for (draw,want) in [(0.7499,PetAction.waving),(0.75,.jumping)] {
            var draws=[0.5,draw,0.5]
            var policy=AutomaticActions(manifest:custom,random:{draws.removeFirst()})
            policy.update(enabled:true,intervalSeconds:60,available:true,at:.zero)
            XCTAssertEqual(policy.takeAction(at:.seconds(60),cursorNear:{false}),want)
        }
        var only=AutomaticActions(manifest:try manifest(actions:["jumping"]),random:{0})
        only.update(enabled:true,intervalSeconds:60,available:true,at:.zero)
        XCTAssertEqual(only.takeAction(at:.seconds(45),cursorNear:{false}),.jumping)
    }
    func testCooldownWaitsUntilEarliestEligibleRuleWithoutBusyPolling() throws {
        var policy=AutomaticActions(manifest:try manifest(behavior:rules([["action":"failed","cooldownSeconds":60]]),actions:["failed"]),random:{0})
        policy.update(enabled:true,intervalSeconds:15,available:true,at:.zero)
        XCTAssertEqual(policy.takeAction(at:.milliseconds(11250),cursorNear:{false}),.failed)
        XCTAssertNil(policy.takeAction(at:.milliseconds(22500),cursorNear:{false}))
        XCTAssertEqual(policy.nextDeadline,.milliseconds(71250))
        XCTAssertNil(policy.takeAction(at:.seconds(71),cursorNear:{false}))
        XCTAssertEqual(policy.takeAction(at:.milliseconds(71250),cursorNear:{false}),.failed)
    }
    func testDueConditionsUseBoundedPollingAndIndependentRuleCooldowns() throws {
        let value=try manifest(behavior:rules([["condition":"cursorNear","action":"waving","cooldownSeconds":60],["condition":"cursorFar","action":"jumping","cooldownSeconds":5]]))
        var policy=AutomaticActions(manifest:value,random:{0})
        policy.update(enabled:true,intervalSeconds:15,available:true,at:.zero)
        XCTAssertEqual(policy.takeAction(at:.milliseconds(11250),cursorNear:{true}),.waving)
        XCTAssertNil(policy.takeAction(at:.milliseconds(22500),cursorNear:{true}))
        XCTAssertEqual(policy.nextDeadline,.seconds(23))
        XCTAssertNil(policy.takeAction(at:.milliseconds(22750),cursorNear:{false}))
        XCTAssertEqual(policy.takeAction(at:.seconds(23),cursorNear:{false}),.jumping)
    }
    func testSuppressionFreezesRemainingWaitAndDisableStartsFreshInterval() throws {
        var policy=AutomaticActions(manifest:try manifest(),random:{0})
        policy.update(enabled:true,intervalSeconds:60,available:true,at:.zero)
        policy.update(enabled:true,intervalSeconds:60,available:false,at:.seconds(10))
        XCTAssertNil(policy.nextDeadline)
        XCTAssertNil(policy.takeAction(at:.seconds(100),cursorNear:{false}))
        policy.update(enabled:true,intervalSeconds:60,available:true,at:.seconds(100))
        XCTAssertEqual(policy.nextDeadline,.seconds(135))
        policy.update(enabled:false,intervalSeconds:60,available:true,at:.seconds(110))
        XCTAssertNil(policy.nextDeadline)
        policy.update(enabled:true,intervalSeconds:60,available:true,at:.seconds(120))
        XCTAssertEqual(policy.nextDeadline,.seconds(165))
        policy.update(enabled:true,intervalSeconds:120,available:true,at:.seconds(130))
        XCTAssertEqual(policy.nextDeadline,.seconds(220))
    }
    func testNearConditionUsesDistanceToRectangleWithEightyPointRadius() {
        let bounds=CGRect(x:100,y:200,width:192,height:208)
        for (point,want) in [(CGPoint(x:196,y:304),true),(CGPoint(x:20,y:200),true),(CGPoint(x:19.9,y:200),false),(CGPoint(x:52,y:136),true),(CGPoint(x:51,y:136),false)] {
            XCTAssertEqual(AutomaticActions.isCursorNear(point,bounds:bounds),want)
        }
    }
    func testCooldownElapsesDuringSuppressionAfterGlobalWaitHasFinished() throws {
        var policy=AutomaticActions(manifest:try manifest(behavior:rules([["action":"waving","cooldownSeconds":60]])),random:{0})
        policy.update(enabled:true,intervalSeconds:15,available:true,at:.zero)
        XCTAssertEqual(policy.takeAction(at:.milliseconds(11250),cursorNear:{false}),.waving)
        XCTAssertNil(policy.takeAction(at:.milliseconds(22500),cursorNear:{false}))
        policy.update(enabled:true,intervalSeconds:15,available:false,at:.seconds(30))
        policy.update(enabled:true,intervalSeconds:15,available:true,at:.seconds(100))
        XCTAssertEqual(policy.takeAction(at:.seconds(100),cursorNear:{false}),.waving)
    }
}
