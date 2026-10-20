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
        let session=PetSession(skin:skin,now:{now}); defer { session.prepareToExit() }
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
    func testErrorStatusHasNoUsablePetCommands() {
        _=NSApplication.shared
        let status=StatusBarController(session:nil,error:"皮肤无效",onQuit:{})
        defer { status.dispose() }
        XCTAssertFalse(status.visibilityItem.isEnabled); XCTAssertFalse(status.recallItem.isEnabled)
    }
}
