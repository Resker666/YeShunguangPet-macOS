import XCTest
@testable import PetCore

final class CompanionSettingsTests:XCTestCase {
    private var directory:URL!,url:URL!
    override func setUpWithError()throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        url=directory.appendingPathComponent("settings.json")
    }
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:directory)}
    private func configuration()throws->[String:Any] {
        let shortcuts=[ShortcutBinding(action:.recall,combination:.init(keyCode:0,modifiers:[.control,.option]))]
        try SettingsStore(url:url).save(.init(placement:nil,preferences:.init(scale:1.5,alwaysOnTop:false,lookAtMouse:false,speechEnabled:true,keyboardShortcuts:shortcuts,snapToEdges:true,positionLocked:true),selectedSkinID:UUID().uuidString))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        object["schemaVersion"]=10
        var p=try XCTUnwrap(object["preferences"] as? [String:Any])
        p["focusMinutes"]=25;p["breakMinutes"]=5;p["speechOverrides"]=[String:Any]()
        object["preferences"]=p;return object
    }
    func testVersionTenLoadsValidCompanionConfiguration()throws {
        let object=try configuration()
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        guard case .loaded(let saved)=SettingsStore(url:url).load() else{return XCTFail("valid schema10 must load")}
        XCTAssertEqual(saved.preferences.scale,1.5);XCTAssertTrue(saved.preferences.positionLocked)
        try SettingsStore(url:url).save(saved)
        let reloaded=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(reloaded["schemaVersion"] as? Int,10)
    }
    func testVersionNineMigrationPreservesAllPreferencesPlacementAndSelection()throws {
        var object=try configuration();object["schemaVersion"]=9
        var p=try XCTUnwrap(object["preferences"] as? [String:Any]);p.removeValue(forKey:"focusMinutes");p.removeValue(forKey:"breakMinutes");p.removeValue(forKey:"speechOverrides");object["preferences"]=p
        let placement=PlacementSnapshot(screenID:"main",origin:CGPoint(x:23,y:45),visibleFrame:CGRect(x:0,y:0,width:1000,height:800))
        object["placement"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(placement))
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        guard case .loaded(let saved)=SettingsStore(url:url).load() else{return XCTFail("schema9 must migrate")}
        XCTAssertEqual(saved.placement,placement);XCTAssertEqual(saved.selectedSkinID,object["selectedSkinID"] as? String)
        XCTAssertEqual(saved.preferences.scale,1.5);XCTAssertFalse(saved.preferences.alwaysOnTop);XCTAssertFalse(saved.preferences.lookAtMouse)
        XCTAssertTrue(saved.preferences.speechEnabled);XCTAssertTrue(saved.preferences.snapToEdges);XCTAssertTrue(saved.preferences.positionLocked)
        try SettingsStore(url:url).save(saved)
        let encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        let newP=try XCTUnwrap(encoded["preferences"] as? [String:Any])
        XCTAssertEqual(encoded["schemaVersion"] as? Int,10);XCTAssertEqual(newP["focusMinutes"] as? Int,25);XCTAssertEqual(newP["breakMinutes"] as? Int,5)
        XCTAssertEqual((newP["speechOverrides"] as? [String:Any])?.count,0)
        for (key,value) in p {XCTAssertEqual(String(describing:newP[key]!),String(describing:value),key)}
    }
    func testVersionTenMissingAndInvalidNewFieldsRemainByteIdentical()throws {
        let valid=try configuration(), originalP=try XCTUnwrap(valid["preferences"] as? [String:Any])
        var invalid=[[String:Any]]()
        for key in ["focusMinutes","breakMinutes","speechOverrides"] {var p=originalP;p.removeValue(forKey:key);invalid.append(p)}
        for (key,value) in [("focusMinutes",0),("focusMinutes",121),("breakMinutes",0),("breakMinutes",61)] {var p=originalP;p[key]=value;invalid.append(p)}
        var boolean=originalP;boolean["focusMinutes"]=true;invalid.append(boolean)
        for p in invalid {
            var object=valid;object["preferences"]=p
            let bytes=try JSONSerialization.data(withJSONObject:object);try bytes.write(to:url)
            let store=SettingsStore(url:url)
            guard case .protectedFile=store.load() else{XCTFail("invalid schema10 accepted");continue}
            XCTAssertThrowsError(try store.save(.init(placement:nil)));XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }
}
