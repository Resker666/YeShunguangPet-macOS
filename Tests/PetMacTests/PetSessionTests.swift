import AppKit
import XCTest
import PetCore

@MainActor final class PetSessionTests: XCTestCase {
    func testRestoredPreferencesResizeBeforePlacementAndSetWindowLevel() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let url=directory.appendingPathComponent("settings.json")
        try SettingsStore(url:url).save(PetSettings(placement:.init(screenID:"test",origin:CGPoint(x:960,y:660),visibleFrame:CGRect(x:0,y:0,width:1000,height:700)),preferences:.init(scale:1.5,alwaysOnTop:false)))
        let session=PetSession(skin:skin,now:{.zero},settings:SettingsStore(url:url),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]})
        defer { session.prepareToExit() }
        session.start()
        XCTAssertEqual(session.panel.frame.size,CGSize(width:48,height:48))
        XCTAssertEqual(session.view.bounds.size,CGSize(width:48,height:48))
        XCTAssertEqual(session.panel.frame.origin,CGPoint(x:952,y:652))
        XCTAssertEqual(session.panel.level,.normal)
        XCTAssertFalse(session.panel.canBecomeKey)
        XCTAssertTrue(session.requestExit())
        guard case .loaded(let saved)=SettingsStore(url:url).load() else { return XCTFail("settings missing") }
        XCTAssertEqual(saved.preferences,PetPreferences(scale:1.5,alwaysOnTop:false))
    }
    func testSettingsMenuOpensAReusableWindowWithoutChangingPetVisibility() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let session=PetSession(skin:try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory)),now:{.zero},settings:SettingsStore(url:directory.appendingPathComponent("settings.json")),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]})
        defer { session.prepareToExit() }
        session.start(); session.setVisible(false)
        let status=StatusBarController(session:session,onQuit:{})
        defer { status.dispose() }
        let entry=try XCTUnwrap(status.menu.items.first { $0.title == "设置…" })
        XCTAssertTrue(entry.isEnabled)
        status.menu.performActionForItem(at:status.menu.index(of:entry))
        let window=try XCTUnwrap(NSApp.windows.first { $0.title == "叶瞬光桌宠设置" })
        XCTAssertTrue(window.isVisible); XCTAssertTrue(window.canBecomeKey)
        window.close()
        status.menu.performActionForItem(at:status.menu.index(of:entry))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "叶瞬光桌宠设置" }.count,1)
        XCTAssertFalse(session.panel.isVisible); XCTAssertEqual(session.scheduler.pendingCount,0)
        XCTAssertFalse(session.gate.exiting)
    }
    func testHiddenSleepWakeDoesNotRestartAndMenuReflectsVisibility() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        var now=Duration.zero
        let session=PetSession(skin:skin,now:{now},settings:SettingsStore(url:directory.appendingPathComponent("settings.json")),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]}); defer { session.prepareToExit() }
        let status=StatusBarController(session:session,onQuit:{})
        defer { status.dispose() }
        session.start(); status.refresh()
        XCTAssertEqual(status.visibilityItem.title,"隐藏角色")
        session.setVisible(false); session.setSleeping(true); now = .seconds(3600); session.setSleeping(false)
        XCTAssertEqual(session.scheduler.pendingCount,0); XCTAssertFalse(session.panel.isVisible)
        status.refresh(); XCTAssertEqual(status.visibilityItem.title,"显示角色")
        session.setVisible(true); session.setSleeping(false)
        XCTAssertEqual(session.scheduler.pendingCount,1)
        session.prepareToExit(); XCTAssertEqual(session.scheduler.pendingCount,0)
    }
    func testCorruptConfigurationNotOverwrittenByRecallOrExit() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let url=directory.appendingPathComponent("settings.json"), bad=Data("{broken".utf8)
        try bad.write(to:url)
        let session=PetSession(skin:skin,now:{.zero},settings:SettingsStore(url:url),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]})
        defer { session.prepareToExit() }
        session.start(); session.recall(); session.finishDrag()
        XCTAssertFalse(session.requestExit())
        XCTAssertEqual(try Data(contentsOf:url),bad)
        XCTAssertNotNil(session.persistenceError)
        session.resetProtectedSettings(); XCTAssertTrue(session.requestExit())
        XCTAssertNotEqual(try Data(contentsOf:url),bad)
    }
    func testHiddenDisplayChangeAndSavedPositionRestore() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let url=directory.appendingPathComponent("settings.json")
        var screens=[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]
        let session=PetSession(skin:skin,now:{.zero},settings:SettingsStore(url:url),screens:{screens})
        session.start(); session.panel.setFrameOrigin(CGPoint(x:123,y:234)); session.finishDrag(); XCTAssertTrue(session.requestExit()); session.prepareToExit()
        let reopened=PetSession(skin:skin,now:{.zero},settings:SettingsStore(url:url),screens:{screens})
        defer { reopened.prepareToExit() }
        reopened.start(); XCTAssertEqual(reopened.panel.frame.origin,CGPoint(x:123,y:234))
        reopened.setVisible(false); screens=[ScreenArea(id:"new",visibleFrame:CGRect(x:-1000,y:0,width:800,height:600),isPrimary:true)]; reopened.screensChanged()
        XCTAssertFalse(reopened.panel.isVisible); XCTAssertEqual(reopened.scheduler.pendingCount,0)
        reopened.setVisible(true); XCTAssertTrue(reopened.panel.frame.minX<0)
    }
    func testErrorStatusHasNoUsablePetCommands() {
        _=NSApplication.shared
        let status=StatusBarController(session:nil,error:"皮肤无效",onQuit:{})
        defer { status.dispose() }
        XCTAssertFalse(status.visibilityItem.isEnabled); XCTAssertFalse(status.recallItem.isEnabled)
    }
}

extension PetSessionTests {
    func testLivePreferencesClampOnNegativeScreenAndPersistWhileHidden() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let url=directory.appendingPathComponent("settings.json")
        let screens=[ScreenArea(id:"left",visibleFrame:CGRect(x:-200,y:-100,width:180,height:120),isPrimary:true)]
        var now=Duration.zero
        let session=PetSession(skin:skin,now:{now},settings:SettingsStore(url:url),screens:{screens})
        defer { session.prepareToExit() }
        session.start(); session.panel.setFrameOrigin(CGPoint(x:-52,y:-12))
        now = .milliseconds(250); session.setVisible(false)
        let model=SettingsModel(session:session)
        model.setScale(2); model.setAlwaysOnTop(false)
        XCTAssertEqual(session.panel.frame,CGRect(x:-84,y:-44,width:64,height:64))
        XCTAssertEqual(session.view.bounds.size,CGSize(width:64,height:64))
        XCTAssertEqual(session.panel.level,.normal)
        XCTAssertFalse(session.panel.isVisible); XCTAssertEqual(session.scheduler.pendingCount,0)
        now = .seconds(3600); session.setVisible(true)
        XCTAssertEqual(session.playback.sample().index,0)
        XCTAssertEqual(session.playback.sample().untilNextFrame,.milliseconds(50))
        XCTAssertTrue(session.requestExit()); session.prepareToExit()
        let reopened=PetSession(skin:skin,now:{now},settings:SettingsStore(url:url),screens:{screens})
        defer { reopened.prepareToExit() }
        reopened.start()
        XCTAssertEqual(reopened.panel.frame,CGRect(x:-84,y:-44,width:64,height:64))
        XCTAssertEqual(reopened.panel.level,.normal)
    }
    func testPreferenceSaveFailureIsVisibleAndRetryKeepsAllSettings() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let url=directory.appendingPathComponent("settings.json")
        var fail=true
        let store=SettingsStore(url:url,write:{ data,url in
            if fail { throw NSError(domain:"disk",code:1) }
            try data.write(to:url,options:.atomic)
        })
        let session=PetSession(skin:skin,now:{.zero},settings:store,screens:{[]})
        defer { session.prepareToExit() }
        session.start()
        let status=StatusBarController(session:session,onQuit:{})
        defer { status.dispose() }
        status.menu.performActionForItem(at:status.menu.index(of:status.settingsItem))
        let model=try XCTUnwrap(status.settingsController?.model)
        model.setScale(0.5); model.setAlwaysOnTop(false)
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(session.requestExit()); XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        fail=false; session.retrySave()
        XCTAssertNil(model.saveError)
        guard case .loaded(let saved)=SettingsStore(url:url).load() else { return XCTFail("preferences not saved without displays") }
        XCTAssertNil(saved.placement); XCTAssertEqual(saved.preferences,PetPreferences(scale:0.5,alwaysOnTop:false))
        XCTAssertEqual(session.scheduler.pendingCount,0)
        model.setScale(.infinity)
        XCTAssertEqual(session.preferences.scale,0.5)
    }
    func testPreferenceChangesDoNotOverwriteProtectedFileUntilExplicitReset() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let url=directory.appendingPathComponent("settings.json"), original=Data("{broken".utf8)
        try original.write(to:url)
        let session=PetSession(skin:skin,now:{.zero},settings:SettingsStore(url:url),screens:{[ScreenArea(id:"small",visibleFrame:CGRect(x:0,y:0,width:40,height:40),isPrimary:true)]})
        defer { session.prepareToExit() }
        session.start(); session.setPreferences(.init(scale:2,alwaysOnTop:false))
        XCTAssertEqual(session.panel.frame,CGRect(x:0,y:0,width:64,height:64))
        XCTAssertEqual(try Data(contentsOf:url),original)
        XCTAssertTrue(session.protectedSettings); XCTAssertFalse(session.requestExit())
        session.resetProtectedSettings()
        guard case .loaded(let saved)=SettingsStore(url:url).load() else { return XCTFail("reset failed") }
        XCTAssertEqual(saved.preferences,PetPreferences(scale:2,alwaysOnTop:false))
        let backups=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.contains("backup-")}
        XCTAssertEqual(backups.count,1); XCTAssertEqual(try Data(contentsOf:backups[0]),original)
    }
    func testInterruptedDragFinalizesPositionAndReturnsToIdle() throws {
        for interruption in ["menu","hide","sleep","display","scale"] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:directory) }
            let manifest=try SkinFixtures.writePackage(in:directory)
            let animation: [String:Any] = ["row":0,"durationsMs":[300,200],"loop":true]
            try SkinFixtures.manifest(["animations":["idle":animation,"runningRight":animation]]).write(to:manifest)
            let url=directory.appendingPathComponent("settings.json")
            var now=Duration.zero
            let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{now},settings:SettingsStore(url:url),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]})
            defer { session.prepareToExit() }
            session.start()
            session.view.onDown?(.zero,1)
            session.view.onMove?(CGPoint(x:1000,y:0))
            XCTAssertEqual(session.action,.runningRight)
            switch interruption {
            case "hide": session.setVisible(false); session.setVisible(true)
            case "sleep": session.setSleeping(true); session.setSleeping(false)
            case "display": session.screensChanged()
            case "scale": session.setPreferences(.init(scale:2))
            default: session.cancelInput()
            }
            session.view.onUp?(CGPoint(x:1000,y:0))
            now = .seconds(1)
            XCTAssertTrue(session.interaction.expireClick().isEmpty)
            XCTAssertEqual(session.action,.idle,interruption)
            XCTAssertEqual(session.panel.frame.maxX,1000,accuracy:0.001,interruption)
            guard case .loaded(let saved)=SettingsStore(url:url).load() else { XCTFail("interrupted drag not saved: \(interruption)"); continue }
            XCTAssertEqual(saved.placement?.origin,session.panel.frame.origin,interruption)
            XCTAssertEqual(session.scheduler.pendingCount,1,interruption)
        }
    }
    func testMetricsExportAndFailureDoNotPreventExit() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        var now=Duration.zero
        let session=PetSession(skin:skin,now:{now},settings:SettingsStore(url:directory.appendingPathComponent("settings.json")),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]})
        defer { session.prepareToExit() }
        session.start(); now = .seconds(10)
        let output=directory.appendingPathComponent("metrics.json")
        try session.exportMetrics(to:output)
        let data=try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as! [String:Any]
        XCTAssertEqual(data["durationSeconds"] as? Double,10)
        XCTAssertEqual(data["frameUpdates"] as? Int,1)
        XCTAssertEqual(data["schedulerWakes"] as? Int,0)
        XCTAssertThrowsError(try session.exportMetrics(to:directory.appendingPathComponent("missing/metrics.json")))
        XCTAssertTrue(session.requestExit())
    }
}
