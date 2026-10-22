import AppKit
import XCTest
import PetCore

@MainActor final class HelpDiagnosticsTests:XCTestCase {
    private func status(_ f:ShortcutFixture)->StatusBarController {
        StatusBarController(session:f.session,updates:ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:"0.1.20")!,architecture:.arm64,client:NoReleaseRequests()),registry:f.registry,onQuit:{})
    }
    func testHelpMenuReusesSettingsWithoutOpeningAtStartup()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let status=status(f);defer{status.dispose()}
        XCTAssertNil(status.settingsController)
        let entry=try XCTUnwrap(status.menu.items.first{$0.title=="使用帮助…"})
        status.menu.performActionForItem(at:status.menu.index(of:entry))
        let controller=try XCTUnwrap(status.settingsController)
        XCTAssertEqual(controller.model.selectedTab.rawValue,"help")
        XCTAssertTrue(controller.window?.isVisible==true)
        controller.close();status.menu.performActionForItem(at:status.menu.index(of:entry))
        XCTAssertTrue(controller === status.settingsController)
        XCTAssertEqual(controller.model.selectedTab.rawValue,"help")
    }
    func testHelpEntryRespectsModalAndTerminationGates()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let status=status(f);defer{status.dispose()}
        let help=try XCTUnwrap(status.menu.items.first{$0.title=="使用帮助…"})
        status.menu.performActionForItem(at:status.menu.index(of:status.settingsItem))
        let controller=try XCTUnwrap(status.settingsController),window=try XCTUnwrap(controller.window)
        controller.model.selectedTab = .skin
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        window.beginSheet(sheet,completionHandler:{_ in});defer{window.endSheet(sheet);sheet.orderOut(nil)}
        status.menu.performActionForItem(at:status.menu.index(of:help))
        XCTAssertEqual(controller.model.selectedTab,.skin)
        window.endSheet(sheet);sheet.orderOut(nil)
        status.beginTermination();status.menu.performActionForItem(at:status.menu.index(of:help))
        XCTAssertEqual(controller.model.selectedTab,.skin)
        status.cancelTermination();status.menu.performActionForItem(at:status.menu.index(of:help))
        XCTAssertEqual(controller.model.selectedTab.rawValue,"help")
    }
    func testMenuCopyDoesNotOpenSettingsOrWriteConfiguration()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let before=try Data(contentsOf:f.settingsURL)
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.setString("original",forType:.string)
        let status=StatusBarController(session:f.session,registry:f.registry,diagnosticWriter:{SupportDiagnosticsModel.write($0,to:board)},onQuit:{})
        defer{status.dispose()}
        XCTAssertNil(status.settingsController);XCTAssertEqual(board.string(forType:.string),"original")
        let copy=try XCTUnwrap(status.menu.items.first{$0.title=="复制诊断信息"})
        status.menu.performActionForItem(at:status.menu.index(of:copy))
        let report=try XCTUnwrap(board.string(forType:.string))
        XCTAssertTrue(report.contains("诊断摘要"));XCTAssertFalse(report.contains(f.directory.path))
        XCTAssertNil(status.settingsController);XCTAssertEqual(try Data(contentsOf:f.settingsURL),before)
        XCTAssertEqual(status.updates.state,.idle)
        status.beginTermination();board.clearContents();board.setString("after-exit",forType:.string)
        status.menu.performActionForItem(at:status.menu.index(of:copy))
        XCTAssertEqual(board.string(forType:.string),"after-exit")
    }
    func testCopyDoesNotExposeStartupErrorAndIsAvailableWithoutASession()throws {
        _=NSApplication.shared
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let status=StatusBarController(session:nil,error:"PRIVATE /Users/private/token",diagnosticWriter:{SupportDiagnosticsModel.write($0,to:board)},onQuit:{})
        defer{status.dispose()}
        let copy=try XCTUnwrap(status.menu.items.first{$0.title=="复制诊断信息"})
        XCTAssertTrue(copy.isEnabled);status.menu.performActionForItem(at:status.menu.index(of:copy))
        let report=try XCTUnwrap(board.string(forType:.string))
        XCTAssertTrue(report.contains("会话未启动"));XCTAssertFalse(report.contains("PRIVATE"));XCTAssertFalse(report.contains("private"))
    }
}
