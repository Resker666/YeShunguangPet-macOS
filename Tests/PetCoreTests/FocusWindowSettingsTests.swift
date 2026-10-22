import XCTest
@testable import PetCore

final class FocusWindowSettingsTests:XCTestCase {
    private var directory:URL!,url:URL!
    override func setUpWithError()throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        url=directory.appendingPathComponent("settings.json")
    }
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:directory)}
    private func configuration(version:Int)throws->[String:Any] {
        let placement=PlacementSnapshot(screenID:"main",origin:CGPoint(x:123,y:234),visibleFrame:CGRect(x:0,y:0,width:1400,height:900))
        try SettingsStore(url:url).save(.init(placement:placement,preferences:.init(scale:1.5,alwaysOnTop:false,speechEnabled:true,keyboardShortcuts:[.init(action:.recall,combination:.init(keyCode:0,modifiers:[.control,.option]))],positionLocked:true,focusMinutes:45,breakMinutes:10,speechOverrides:["ye-shunguang":.defaults]),selectedSkinID:"4AEFD8B7-6164-482F-997F-13ABFBB4275D"))
        var result=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]);result["schemaVersion"]=version
        var p=try XCTUnwrap(result["preferences"] as? [String:Any]);p.removeValue(forKey:"focusWindow");p.removeValue(forKey:"focusCompletionSound");result["preferences"]=p
        return result
    }
    func testVersionTenMigrationAddsVisiblePinnedWindowWithoutLosingPersonalState()throws {
        let original=try configuration(version:10)
        try JSONSerialization.data(withJSONObject:original).write(to:url)
        let store=SettingsStore(url:url)
        guard case .loaded(let saved)=store.load() else{return XCTFail("valid v10 must migrate")}
        try store.save(saved)
        let result=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(result["schemaVersion"] as? Int,12)
        let p=try XCTUnwrap(result["preferences"] as? [String:Any])
        let window=try XCTUnwrap(p["focusWindow"] as? [String:Any])
        XCTAssertEqual(window["isVisible"] as? Bool,true);XCTAssertEqual(window["alwaysOnTop"] as? Bool,true);XCTAssertNil(window["placement"])
        for key in ["placement","selectedSkinID"] {XCTAssertEqual(try JSONSerialization.data(withJSONObject:[key:result[key]!],options:.sortedKeys),try JSONSerialization.data(withJSONObject:[key:original[key]!],options:.sortedKeys))}
        var restored=p;restored.removeValue(forKey:"focusWindow");restored.removeValue(forKey:"focusCompletionSound")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:restored,options:.sortedKeys),try JSONSerialization.data(withJSONObject:original["preferences"]!,options:.sortedKeys))
    }
    func testVersionElevenRestoresIndependentWindowGeometryAndHiddenState()throws {
        var object=try configuration(version:11),p=try XCTUnwrap(object["preferences"] as? [String:Any])
        let window:[String:Any]=["isVisible":false,"alwaysOnTop":false,"compact":false,"placement":["screenID":"left","x":-500,"y":200,"visibleX":-1440,"visibleY":0,"visibleWidth":1440,"visibleHeight":900]]
        p["focusWindow"]=window;object["preferences"]=p;try JSONSerialization.data(withJSONObject:object).write(to:url)
        let store=SettingsStore(url:url)
        guard case .loaded(let saved)=store.load() else{return XCTFail("valid v11 window must load")}
        try store.save(saved)
        let result=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),preferences=try XCTUnwrap(result["preferences"] as? [String:Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:preferences["focusWindow"]!,options:.sortedKeys),try JSONSerialization.data(withJSONObject:window,options:.sortedKeys))
    }
    func testInvalidCurrentWindowConfigurationProtectsOriginalBytes()throws {
        let original=try configuration(version:11),p=try XCTUnwrap(original["preferences"] as? [String:Any])
        let invalid:[Any?]=[nil,["isVisible":true],["alwaysOnTop":true],["isVisible":1,"alwaysOnTop":true],["isVisible":true,"alwaysOnTop":"yes"],["isVisible":true,"alwaysOnTop":true,"placement":["screenID":"main","x":0,"y":0,"visibleX":0,"visibleY":0,"visibleWidth":0,"visibleHeight":900]]]
        for value in invalid {
            var object=original,preferences=p;preferences["focusWindow"]=value;object["preferences"]=preferences
            let bytes=try JSONSerialization.data(withJSONObject:object);try bytes.write(to:url)
            let store=SettingsStore(url:url)
            guard case .protectedFile=store.load() else{XCTFail("invalid window accepted");continue}
            XCTAssertThrowsError(try store.save(.init(placement:nil)));XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }
    func testVersionElevenMigrationPreservesWindowAndAddsSilentNormalDefaults()throws {
        var object=try configuration(version:11),p=try XCTUnwrap(object["preferences"] as? [String:Any])
        p.removeValue(forKey:"focusCompletionSound")
        let window:[String:Any] = ["isVisible":false,"alwaysOnTop":false,"placement":["screenID":"left","x":-500,"y":200,"visibleX":-1440,"visibleY":0,"visibleWidth":1440,"visibleHeight":900]]
        p["focusWindow"]=window;object["preferences"]=p
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        let store=SettingsStore(url:url)
        guard case .loaded(let saved)=store.load() else{return XCTFail("v11 must migrate")}
        try store.save(saved)
        let result=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),newP=try XCTUnwrap(result["preferences"] as? [String:Any])
        XCTAssertEqual(result["schemaVersion"] as? Int,12)
        XCTAssertEqual(newP["focusCompletionSound"] as? Bool,false)
        var newWindow=try XCTUnwrap(newP["focusWindow"] as? [String:Any])
        XCTAssertEqual(newWindow.removeValue(forKey:"compact") as? Bool,false)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:newWindow,options:.sortedKeys),try JSONSerialization.data(withJSONObject:window,options:.sortedKeys))
        for (key,value) in p where key != "focusWindow" {XCTAssertEqual(try JSONSerialization.data(withJSONObject:[key:newP[key]!],options:.sortedKeys),try JSONSerialization.data(withJSONObject:[key:value],options:.sortedKeys))}
    }
    func testCurrentReminderAndCompactRoundTripAndStrictProtection()throws {
        var object=try configuration(version:12),p=try XCTUnwrap(object["preferences"] as? [String:Any])
        p["focusWindow"]=["isVisible":true,"alwaysOnTop":false,"compact":true];p["focusCompletionSound"]=true;object["preferences"]=p
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        let store=SettingsStore(url:url)
        guard case .loaded(let saved)=store.load() else{return XCTFail("v12 must load")}
        try store.save(saved)
        let encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:encoded["preferences"]!,options:.sortedKeys),try JSONSerialization.data(withJSONObject:p,options:.sortedKeys))
        for key in ["focusCompletionSound","compact"] {
            for value:Any? in [nil,"yes",1,NSNull()] {
                var badP=p
                if key == "compact" {var w=try XCTUnwrap(p["focusWindow"] as? [String:Any]);w[key]=value;badP["focusWindow"]=w}else{badP[key]=value}
                var bad=object;bad["preferences"]=badP
                let bytes=try JSONSerialization.data(withJSONObject:bad);try bytes.write(to:url)
                let blocked=SettingsStore(url:url)
                guard case .protectedFile=blocked.load() else{XCTFail("invalid new field accepted");continue}
                XCTAssertThrowsError(try blocked.save(.init(placement:nil)));XCTAssertEqual(try Data(contentsOf:url),bytes)
            }
        }
    }
}
