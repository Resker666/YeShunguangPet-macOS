import AppKit
import XCTest
import PetCore

@MainActor final class PetSessionTests: XCTestCase {
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
