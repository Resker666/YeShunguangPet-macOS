import XCTest
@testable import PetCore

final class SettingsStoreTests: XCTestCase {
    var directory: URL!, settingsURL: URL!
    let placement=PlacementSnapshot(screenID:"main",origin:CGPoint(x:100,y:200),visibleFrame:CGRect(x:0,y:40,width:1000,height:700))
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); settingsURL=directory.appendingPathComponent("settings.json") }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func testMissingSaveAndReopen() throws {
        let store=SettingsStore(url:settingsURL)
        guard case .missing=store.load() else { return XCTFail("missing") }
        try store.save(PetSettings(placement:placement))
        guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("loaded") }
        XCTAssertEqual(saved.placement,placement)
    }
    func testVersionTwoPreferencesSurviveLoadAndSave() throws {
        let object: [String:Any] = ["schemaVersion":2,"placement":["screenID":"main","x":100,"y":200,"visibleX":0,"visibleY":40,"visibleWidth":1000,"visibleHeight":700],"preferences":["scale":1.5,"alwaysOnTop":false]]
        try JSONSerialization.data(withJSONObject:object).write(to:settingsURL)
        let store=SettingsStore(url:settingsURL)
        guard case .loaded(let saved)=store.load() else { return XCTFail("valid preferences must load") }
        try store.save(saved)
        let encoded=try JSONSerialization.jsonObject(with:Data(contentsOf:settingsURL)) as! [String:Any]
        let preferences=try XCTUnwrap(encoded["preferences"] as? [String:Any])
        XCTAssertEqual(preferences["scale"] as? Double,1.5)
        XCTAssertEqual(preferences["alwaysOnTop"] as? Bool,false)
    }
    func testImportedSelectionSurvivesLoadAndSaveWithPreferencesAndPosition() throws {
        let object: [String:Any] = ["schemaVersion":3,"placement":["screenID":"main","x":100,"y":200,"visibleX":0,"visibleY":40,"visibleWidth":1000,"visibleHeight":700],"preferences":["scale":1.5,"alwaysOnTop":false],"selectedSkinID":"4AEFD8B7-6164-482F-997F-13ABFBB4275D"]
        try JSONSerialization.data(withJSONObject:object).write(to:settingsURL)
        let store=SettingsStore(url:settingsURL)
        guard case .loaded(let saved)=store.load() else { return XCTFail("valid imported selection must load") }
        try store.save(saved)
        let encoded=try JSONSerialization.jsonObject(with:Data(contentsOf:settingsURL)) as! [String:Any]
        XCTAssertEqual(encoded["schemaVersion"] as? Int,6)
        XCTAssertEqual(encoded["selectedSkinID"] as? String,"4AEFD8B7-6164-482F-997F-13ABFBB4275D")
        XCTAssertEqual(saved.placement,placement)
        XCTAssertEqual(saved.preferences,PetPreferences(scale:1.5,alwaysOnTop:false))
    }
    func testLegacyPositionMigratesWithDefaultPreferences() throws {
        try JSONSerialization.data(withJSONObject:["schemaVersion":1,"placement":JSONSerialization.jsonObject(with:JSONEncoder().encode(placement))]).write(to:settingsURL)
        let store=SettingsStore(url:settingsURL)
        guard case .loaded(let saved)=store.load() else { return XCTFail("legacy position must load") }
        try store.save(saved)
        let encoded=try JSONSerialization.jsonObject(with:Data(contentsOf:settingsURL)) as! [String:Any]
        XCTAssertEqual(encoded["schemaVersion"] as? Int,6)
        let preferences=try XCTUnwrap(encoded["preferences"] as? [String:Any])
        XCTAssertEqual(preferences["scale"] as? Double,1)
        XCTAssertEqual(preferences["alwaysOnTop"] as? Bool,true)
        let position=try XCTUnwrap(encoded["placement"] as? [String:Any])
        XCTAssertEqual(position["x"] as? Double,100)
        XCTAssertEqual(position["y"] as? Double,200)
    }
    func testInvalidPreferencesAndUnknownVersionsStayProtected() throws {
        let invalid=[#"{"scale":0.49,"alwaysOnTop":true}"#,#"{"scale":2.01,"alwaysOnTop":true}"#,#"{"scale":true,"alwaysOnTop":false}"#,#"{"scale":1,"alwaysOnTop":1}"#,#"{"scale":1}"#,#"{"scale":1,"Scale":2,"alwaysOnTop":true}"#,#"null"#]
        for value in invalid {
            let bad=Data("{\"schemaVersion\":2,\"preferences\":\(value)}".utf8)
            try bad.write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { XCTFail("invalid preferences accepted: \(value)"); continue }
            XCTAssertThrowsError(try store.save(PetSettings(placement:placement)))
            XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
        }
        for version in ["99","2.0","2e0","true"] {
            let bad=Data("{\"schemaVersion\":\(version),\"preferences\":{\"scale\":1,\"alwaysOnTop\":true}}".utf8)
            try bad.write(to:settingsURL)
            guard case .protectedFile=SettingsStore(url:settingsURL).load() else { XCTFail("unsupported version accepted"); continue }
            XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
        }
    }
    func testPreferencesSaveWithoutDisplayPlacementAndRejectNonfiniteScale() throws {
        for scale in [0.5,2.0] {
            let store=SettingsStore(url:settingsURL)
            try store.save(PetSettings(placement:nil,preferences:.init(scale:scale,alwaysOnTop:false)))
            guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("preferences lost without placement") }
            XCTAssertNil(saved.placement); XCTAssertEqual(saved.preferences.scale,scale)
            XCTAssertFalse(saved.preferences.alwaysOnTop)
        }
        let original=try Data(contentsOf:settingsURL)
        for scale in [Double.nan,Double.infinity,0.0,3.0] {
            XCTAssertThrowsError(try SettingsStore(url:settingsURL).save(PetSettings(placement:placement,preferences:.init(scale:scale))))
            XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        }
    }
    func testCorruptSettingsRemainByteIdenticalUntilExplicitReset() throws {
        for bad in [Data("{broken".utf8),Data(#"{"schemaVersion":2}"#.utf8),Data(repeating:32,count:65537)] {
            try bad.write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { return XCTFail("protected") }
            XCTAssertThrowsError(try store.save(PetSettings(placement:placement)))
            XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
            try store.backupAndReset(); try store.save(PetSettings(placement:placement))
            let backups=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.contains("backup-")}
            XCTAssertTrue(try backups.contains { try Data(contentsOf:$0)==bad })
        }
    }
    func testAtomicWriteFailureKeepsOriginalAndCanRetry() throws {
        let store=SettingsStore(url:settingsURL); try store.save(PetSettings(placement:placement)); let original=try Data(contentsOf:settingsURL)
        let failing=SettingsStore(url:settingsURL,write:{_,_ in throw NSError(domain:"disk",code:1)})
        _=failing.load(); XCTAssertThrowsError(try failing.save(PetSettings(placement:placement))); XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        try store.save(PetSettings(placement:placement))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted(),["settings.json"])
    }
    func testBackupFailureLeavesOriginalAndProtectionIntact() throws {
        let bad=Data("{broken".utf8); try bad.write(to:settingsURL)
        let store=SettingsStore(url:settingsURL,backup:{_,_ in throw NSError(domain:"backup",code:1)})
        _=store.load(); XCTAssertThrowsError(try store.backupAndReset())
        XCTAssertThrowsError(try store.save(PetSettings(placement:placement)))
        XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
    }
    func testInvalidGeometryAndSixtyFourKiBBoundary() throws {
        let store=SettingsStore(url:settingsURL)
        XCTAssertThrowsError(try store.save(PetSettings(placement:.init(screenID:"x",origin:CGPoint(x:Double.infinity,y:0),visibleFrame:placement.visibleFrame))))
        XCTAssertThrowsError(try store.save(PetSettings(placement:.init(screenID:"",origin:.zero,visibleFrame:placement.visibleFrame))))
        XCTAssertThrowsError(try store.save(PetSettings(placement:.init(screenID:"x",origin:.zero,visibleFrame:.zero))))
        try store.save(PetSettings(placement:placement)); let data=try Data(contentsOf:settingsURL)
        try (data+Data(repeating:32,count:65536-data.count)).write(to:settingsURL)
        guard case .loaded=SettingsStore(url:settingsURL).load() else { return XCTFail("64KiB accepted") }
    }
    func testInvalidImportedIDsStayProtectedAndCannotBeSaved() throws {
        for id in ["../escape","/tmp/skin","my-pet",""] {
            let bad=try JSONSerialization.data(withJSONObject:["schemaVersion":3,"preferences":["scale":1,"alwaysOnTop":true],"selectedSkinID":id])
            try bad.write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { XCTFail("invalid imported reference accepted"); continue }
            XCTAssertThrowsError(try store.save(PetSettings(placement:nil,selectedSkinID:id)))
            XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
        }
    }
    func testOldConfigurationsDefaultGazeOnAndSaveCurrentVersionWithoutLosingSelection() throws {
        for version in [1,2,3] {
            var value:[String:Any]=["schemaVersion":version,"placement":["screenID":"main","x":100,"y":200,"visibleX":0,"visibleY":40,"visibleWidth":1000,"visibleHeight":700]]
            if version>1 { value["preferences"]=["scale":1.5,"alwaysOnTop":false] }
            if version==3 { value["selectedSkinID"]="4AEFD8B7-6164-482F-997F-13ABFBB4275D" }
            try JSONSerialization.data(withJSONObject:value).write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .loaded(let saved)=store.load() else { return XCTFail("old configuration must migrate") }
            XCTAssertTrue(saved.preferences.lookAtMouse)
            try store.save(saved)
            let encoded=try JSONSerialization.jsonObject(with:Data(contentsOf:settingsURL)) as! [String:Any]
            XCTAssertEqual(encoded["schemaVersion"] as? Int,6)
            XCTAssertEqual((encoded["preferences"] as? [String:Any])?["lookAtMouse"] as? Bool,true)
            if version==3 { XCTAssertEqual(encoded["selectedSkinID"] as? String,"4AEFD8B7-6164-482F-997F-13ABFBB4275D") }
        }
    }
    func testGazeDisabledSurvivesVersionFourRestart() throws {
        let config=Data(#"{"schemaVersion":4,"preferences":{"scale":1.5,"alwaysOnTop":false,"lookAtMouse":false},"selectedSkinID":"4AEFD8B7-6164-482F-997F-13ABFBB4275D"}"#.utf8)
        try config.write(to:settingsURL)
        let store=SettingsStore(url:settingsURL)
        guard case .loaded(let saved)=store.load() else { return XCTFail("version four must load") }
        XCTAssertFalse(saved.preferences.lookAtMouse)
        try store.save(saved)
        guard case .loaded(let reopened)=SettingsStore(url:settingsURL).load() else { return XCTFail("reopen") }
        XCTAssertEqual(reopened,saved)
    }
    func testInvalidGazeFieldKeepsConfigurationProtected() throws {
        for value in ["null","1","\"false\""] {
            let config=Data("{\"schemaVersion\":4,\"preferences\":{\"scale\":1,\"alwaysOnTop\":true,\"lookAtMouse\":\(value)}}".utf8)
            try config.write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { return XCTFail("invalid gaze setting accepted") }
            XCTAssertThrowsError(try store.save(PetSettings(placement:nil)))
            XCTAssertEqual(try Data(contentsOf:settingsURL),config)
        }
    }
    func testVersionFourMigratesAutomaticActionsOffAndPreservesGazeAndSelection() throws {
        try Data(#"{"schemaVersion":4,"preferences":{"scale":1.5,"alwaysOnTop":false,"lookAtMouse":false},"selectedSkinID":"4AEFD8B7-6164-482F-997F-13ABFBB4275D"}"#.utf8).write(to:settingsURL)
        let store=SettingsStore(url:settingsURL)
        guard case .loaded(let saved)=store.load() else { return XCTFail("version four must migrate") }
        XCTAssertFalse(saved.preferences.automaticActions)
        XCTAssertEqual(saved.preferences.automaticActionIntervalSeconds,60)
        XCTAssertFalse(saved.preferences.lookAtMouse)
        try store.save(saved)
        guard case .loaded(let reopened)=SettingsStore(url:settingsURL).load() else { return XCTFail("reopen") }
        XCTAssertEqual(reopened,saved)
        var preferences=saved.preferences; preferences.automaticActions=true; preferences.automaticActionIntervalSeconds=120
        try store.save(.init(placement:placement,preferences:preferences,selectedSkinID:saved.selectedSkinID))
        guard case .loaded(let enabled)=SettingsStore(url:settingsURL).load() else { return XCTFail("enabled restart") }
        XCTAssertEqual(enabled.preferences,preferences)
        XCTAssertEqual(enabled.selectedSkinID,"4AEFD8B7-6164-482F-997F-13ABFBB4275D")
    }
    func testInvalidAutomaticPreferencesProtectOriginalBytes() throws {
        for fields in [#""automaticActions":1,"automaticActionIntervalSeconds":60"#,#""automaticActions":true,"automaticActionIntervalSeconds":14"#,#""automaticActions":false,"automaticActionIntervalSeconds":121"#,#""automaticActions":true,"automaticActionIntervalSeconds":60.5"#,#""automaticActions":true"#] {
            let data=Data("{\"schemaVersion\":5,\"preferences\":{\"scale\":1,\"alwaysOnTop\":true,\"lookAtMouse\":false,\(fields)}}".utf8)
            try data.write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { XCTFail("invalid automatic preference accepted"); continue }
            XCTAssertThrowsError(try store.save(.init(placement:nil)))
            XCTAssertEqual(try Data(contentsOf:settingsURL),data)
        }
    }
    func testVersionFiveMigratesRoamingOffAndRetainsAutomaticActions() throws {
        try Data(#"{"schemaVersion":5,"preferences":{"scale":1.5,"alwaysOnTop":false,"lookAtMouse":false,"automaticActions":true,"automaticActionIntervalSeconds":15},"selectedSkinID":"4AEFD8B7-6164-482F-997F-13ABFBB4275D"}"#.utf8).write(to:settingsURL)
        let store=SettingsStore(url:settingsURL)
        guard case .loaded(let saved)=store.load() else { return XCTFail("version five migration") }
        XCTAssertFalse(saved.preferences.desktopRoaming);XCTAssertEqual(saved.preferences.roamIntervalSeconds,75)
        XCTAssertTrue(saved.preferences.automaticActions);XCTAssertEqual(saved.preferences.automaticActionIntervalSeconds,15)
        var preferences=saved.preferences;preferences.desktopRoaming=true;preferences.roamIntervalSeconds=20
        try store.save(.init(placement:placement,preferences:preferences,selectedSkinID:saved.selectedSkinID))
        guard case .loaded(let reopened)=SettingsStore(url:settingsURL).load() else { return XCTFail("reopen") }
        XCTAssertEqual(reopened.preferences,preferences);XCTAssertEqual(reopened.selectedSkinID,saved.selectedSkinID);XCTAssertEqual(reopened.placement,placement)
    }
    func testInvalidRoamingPreferencesProtectOriginalBytes() throws {
        for fields in [#""desktopRoaming":1,"roamIntervalSeconds":75"#,#""desktopRoaming":true,"roamIntervalSeconds":19"#,#""desktopRoaming":false,"roamIntervalSeconds":181"#,#""desktopRoaming":true,"roamIntervalSeconds":20.5"#,#""desktopRoaming":true"#] {
            let data=Data("{\"schemaVersion\":6,\"preferences\":{\"scale\":1,\"alwaysOnTop\":true,\"lookAtMouse\":false,\"automaticActions\":false,\"automaticActionIntervalSeconds\":60,\(fields)}}".utf8)
            try data.write(to:settingsURL);let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { XCTFail("invalid roaming preference accepted");continue }
            XCTAssertThrowsError(try store.save(.init(placement:nil)));XCTAssertEqual(try Data(contentsOf:settingsURL),data)
        }
    }
}
