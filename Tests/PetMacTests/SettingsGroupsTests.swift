import AppKit
import XCTest
import PetCore
import ServiceManagement

actor SettingsUpdateSpy:ReleaseFetching {
    private(set) var count=0
    var hold=false
    func setHolding(){hold=true}
    func fetchLatest(architecture:ReleaseArchitecture)async throws->ReleaseInfo {
        count+=1
        while hold && !Task.isCancelled {await Task.yield()}
        try Task.checkCancellation()
        let data=Data(#"{"tag_name":"v0.1.9","draft":false,"prerelease":false,"html_url":"https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.9","body":"old public release","assets":[]}"#.utf8)
        return try ReleaseInfo.parse(data,architecture:architecture)
    }
}
@MainActor final class SettingsGroupsTests:XCTestCase {
    private func updates(_ client:SettingsUpdateSpy)->ReleaseUpdateModel {.init(currentVersion:ReleaseVersion(tag:"0.1.12")!,architecture:.arm64,client:client)}
    private func waitForRequest(_ client:SettingsUpdateSpy)async {
        for _ in 0..<10000 {if await client.count>0{return};await Task.yield()};XCTFail("no request")
    }
    func testFiveGroupsAndManualUpdateMenuOnly()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let client=SettingsUpdateSpy(),model=updates(client)
        let status=StatusBarController(session:f.session,updates:model,registry:f.registry,onQuit:{});defer{status.dispose()}
        status.startShortcuts()
        status.menu.performActionForItem(at:status.menu.index(of:status.settingsItem))
        let window=try XCTUnwrap(status.settingsController)
        XCTAssertEqual(SettingsTab.allCases,[.skin,.general,.interaction,.shortcuts,.about]);XCTAssertEqual(window.model.selectedTab,.skin)
        for tab in SettingsTab.allCases{window.model.selectedTab=tab;status.refresh()}
        f.session.setQuiet(true);status.refresh();let initial=await client.count;XCTAssertEqual(initial,0)
        status.menu.performActionForItem(at:status.menu.index(of:status.checkUpdatesItem));await waitForRequest(client)
        XCTAssertEqual(window.model.selectedTab,.about)
        let count=await client.count;XCTAssertEqual(count,1)
        for _ in 0..<10000 {if model.state != .checking{break};await Task.yield()}
        guard case .success(_,let comparison)=model.state else{return XCTFail("result missing")}
        XCTAssertEqual(comparison,.ahead)
    }
    func testTabReopenAndDropFromEveryGroup()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let window=SettingsWindowController(session:f.session,updates:updates(SettingsUpdateSpy()),shortcuts:f.controller)
        defer{window.close()}
        let archive=f.directory.appendingPathComponent("test.zip")
        try ZIPFixtures.archive([.init("pet.json",Data(contentsOf:f.directory.appendingPathComponent("pet.json"))),.init("spritesheet.png",Data(contentsOf:f.directory.appendingPathComponent("spritesheet.png")))]).write(to:archive)
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.writeObjects([archive as NSURL])
        for tab in SettingsTab.allCases {
            window.present(tab:tab)
            let task=try XCTUnwrap(window.acceptSkinDrop(from:board));await task.value
            XCTAssertEqual(window.model.selectedTab,.skin);XCTAssertNotNil(window.model.candidate)
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.session.library.directory.path))
            window.model.selectedTab = .about;XCTAssertNotNil(window.model.candidate)
            let editGeneration=window.model.shortcutEditGeneration
            window.close();XCTAssertNil(window.model.candidate)
            XCTAssertGreaterThan(window.model.shortcutEditGeneration,editGeneration)
            window.present();XCTAssertEqual(window.model.selectedTab,.about);window.close()
        }
    }
    func testClosingSettingsCancelsCheckWithoutQueryingOnReopen()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let client=SettingsUpdateSpy();await client.setHolding()
        let model=updates(client)
        let window=SettingsWindowController(session:f.session,updates:model,shortcuts:f.controller)
        defer{window.close()}
        window.present(tab:.about);model.check();await waitForRequest(client)
        window.close();XCTAssertEqual(model.state,.idle)
        window.present();for _ in 0..<30{await Task.yield()}
        let count=await client.count;XCTAssertEqual(count,1);XCTAssertEqual(window.model.selectedTab,.about)
    }
    func testModalAndTerminationGatesDoNotRecreateServices()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let client=SettingsUpdateSpy(),model=updates(client);await client.setHolding()
        var loginCalls=0
        let login=LoginItemController(bundleURL:URL(fileURLWithPath:"/Applications/YeShunguangPet.app"),status:{.notRegistered},register:{loginCalls+=1},unregister:{loginCalls+=1})
        let status=StatusBarController(session:f.session,updates:model,registry:f.registry,loginItem:login,onQuit:{});defer{status.dispose()}
        status.startShortcuts();let shortcuts=try XCTUnwrap(status.shortcuts)
        shortcuts.apply(ShortcutFixture.a,to:.toggleQuiet)
        status.menu.performActionForItem(at:status.menu.index(of:status.settingsItem))
        let window=try XCTUnwrap(status.settingsController),native=try XCTUnwrap(window.window)
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        native.beginSheet(sheet,completionHandler:{_ in});defer{native.endSheet(sheet);sheet.orderOut(nil)}
        let id=try XCTUnwrap(f.registry.registered.first?.key)
        f.registry.emit(id);XCTAssertFalse(f.session.isQuiet);XCTAssertTrue(window.hasBlockingSheet)
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.writeObjects([f.directory as NSURL])
        XCTAssertNil(window.acceptSkinDrop(from:board));native.endSheet(sheet);sheet.orderOut(nil)
        f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        f.registry.emit(id,down:false);status.menuWillOpen(status.menu);f.registry.emit(id)
        status.menuDidClose(status.menu);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertFalse(f.session.isQuiet)
        model.check();await waitForRequest(client);status.beginTermination()
        XCTAssertEqual(model.state,.idle);f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertFalse(f.session.isQuiet)
        status.cancelTermination();f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        let calls=f.registry.registerCalls
        for tab in SettingsTab.allCases{window.model.selectedTab=tab;status.refresh()}
        XCTAssertEqual(f.registry.registerCalls,calls);XCTAssertEqual(loginCalls,0)
    }
}
