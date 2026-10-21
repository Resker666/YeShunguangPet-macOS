import XCTest
@testable import PetCore

final class PersonalSpeechTests:XCTestCase {
    func testPrecedenceExplicitEmptyAndFourEvents()throws {
        let personal=SpeechLines(click:["个人"],drag:[],focusCompleted:["完成专注"],breakCompleted:["完成休息"])
        let selected=PersonalSpeech.resolve(id:"robin",skin:.defaults,overrides:["robin":personal])
        XCTAssertEqual(selected,personal);XCTAssertEqual(selected.lines(for:.drag),[])
        XCTAssertEqual(PersonalSpeech.resolve(id:"other",skin:nil,overrides:[:]),.defaults)
        let empty=SpeechLines(click:[],drag:[],focusCompleted:[],breakCompleted:[])
        XCTAssertEqual(PersonalSpeech.resolve(id:"other",skin:empty,overrides:[:]),empty)
        var policy=SpeechPolicy(random:{0})
        XCTAssertEqual(policy.select(lines:personal,event:.click,at:.zero),"个人")
        XCTAssertNil(policy.select(lines:personal,event:.click,at:.seconds(1)))
        XCTAssertEqual(policy.select(lines:personal,event:.focusCompleted,at:.seconds(2)),"完成专注")
        XCTAssertEqual(policy.select(lines:personal,event:.breakCompleted,at:.seconds(3)),"完成休息")
        XCTAssertNil(policy.select(lines:personal,event:.click,at:.seconds(4)))
    }
    func testDraftWhitespaceEmptyAndValidationBoundaries()throws {
        XCTAssertEqual(try PersonalSpeech.parse("  你好  \n\n第二句\r\n"),["你好","第二句"])
        XCTAssertEqual(try PersonalSpeech.parse(" \n \n"),[])
        let valid=String(repeating:"😀",count:40)
        XCTAssertEqual(try PersonalSpeech.parse(valid),[valid])
        for invalid in [valid+"a","含\t控制",Array(repeating:"句",count:9).joined(separator:"\n")] {XCTAssertThrowsError(try PersonalSpeech.parse(invalid))}
        try PersonalSpeech.validate(["robin":.init(click:[valid],drag:[],focusCompleted:[],breakCompleted:[])])
        for id in ["../robin","RoBin","nul","robin\n",String(repeating:"a",count:65)] {XCTAssertThrowsError(try PersonalSpeech.validate([id:.defaults]))}
        var excessive=[String:SpeechLines]();for i in 0..<17 {excessive["role-\(i)"] = .defaults}
        XCTAssertThrowsError(try PersonalSpeech.validate(excessive))
        let line=String(repeating:"中",count:80),lines=Array(repeating:line,count:8)
        var capacity=[String:SpeechLines]();for i in 0..<4 {capacity["role-\(i)"] = .init(click:lines,drag:lines,focusCompleted:lines,breakCompleted:lines)}
        XCTAssertThrowsError(try PersonalSpeech.validate(capacity))
    }
    func testSchemaTenRoundTripAndInvalidOverridesProtectOriginal()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("settings.json")
        var p=PetPreferences();p.focusMinutes=45;p.breakMinutes=10;p.speechOverrides=["robin":.init(click:["甲"],drag:[],focusCompleted:["乙"],breakCompleted:["丙"])]
        try SettingsStore(url:url).save(.init(placement:nil,preferences:p))
        guard case .loaded(let saved)=SettingsStore(url:url).load() else{return XCTFail("roundtrip")}
        XCTAssertEqual(saved.preferences,p)
        let original=try Data(contentsOf:url)
        var invalid=p;invalid.speechOverrides=["robin":.init(click:["bad\nline"],drag:[],focusCompleted:[],breakCompleted:[])]
        XCTAssertThrowsError(try SettingsStore(url:url).save(.init(placement:nil,preferences:invalid)))
        XCTAssertEqual(try Data(contentsOf:url),original)
        var encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any])
        var prefs=try XCTUnwrap(encoded["preferences"] as? [String:Any]);prefs["speechOverrides"]=["robin":["click":["甲"]]];encoded["preferences"]=prefs
        let bad=try JSONSerialization.data(withJSONObject:encoded);try bad.write(to:url)
        guard case .protectedFile=SettingsStore(url:url).load() else{return XCTFail("incomplete four-event override must be protected")}
        XCTAssertEqual(try Data(contentsOf:url),bad)
    }
}
