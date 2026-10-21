import AppKit
import XCTest
import PetCore

@MainActor final class ContextMenuTests:XCTestCase {
    private func event(_ f:ShortcutFixture)throws->NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.session.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    }
    private func status(_ f:ShortcutFixture)->StatusBarController {
        let updates=ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:"0.1.12")!,architecture:.arm64,client:NoReleaseRequests())
        return StatusBarController(session:f.session,updates:updates,registry:f.registry,onQuit:{})
    }
    private func invoke(_ title:String,in menu:NSMenu)throws {
        let item=try XCTUnwrap(menu.items.first{$0.title==title})
        XCTAssertTrue(item.isEnabled);menu.performActionForItem(at:menu.index(of:item))
    }
    func testNativeContextMenuUsesSharedCommandsAndReusableSettings()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let manifest=try SkinFixtures.writePackage(in:f.directory.appendingPathComponent("actions"))
        try SkinFixtures.manifest(["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["durationsMs":[1000],"loop":false],"jumping":["durationsMs":[1000],"loop":false]]]).write(to:manifest)
        try f.session.useImportedSkin(f.session.library.install(SkinLoader.readPackage(manifestURL:manifest)))
        let status=status(f);defer{status.dispose()}
        let menu=try XCTUnwrap(f.session.view.menu(for:event(f)))
        try invoke("挥手",in:menu);XCTAssertEqual(f.session.action,.waving)
        try invoke("跳跃",in:menu);XCTAssertEqual(f.session.action,.jumping)
        try invoke("安静模式",in:menu);XCTAssertTrue(f.session.isQuiet);XCTAssertEqual(status.quietItem.state,.on)
        XCTAssertEqual(menu.items.first{$0.title=="安静模式"}?.state,.on)
        try invoke("设置…",in:menu)
        let controller=try XCTUnwrap(status.settingsController);XCTAssertTrue(controller.window?.isVisible==true)
        controller.close();try invoke("设置…",in:menu);XCTAssertTrue(controller === status.settingsController)
        try invoke("隐藏角色",in:menu);XCTAssertFalse(f.session.isVisible)
        try invoke("显示角色",in:status.menu);XCTAssertTrue(f.session.isVisible)
        XCTAssertFalse(f.session.panel.canBecomeKey);XCTAssertFalse(f.session.panel.canBecomeMain)
    }
    func testContextOpeningCancelsPendingClickAndOverlappingMenusKeepHotKeysSuppressed()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let status=status(f);defer{status.dispose()};status.startShortcuts()
        let shortcuts=try XCTUnwrap(status.shortcuts);shortcuts.apply(ShortcutFixture.a,to:.toggleQuiet)
        let id=try XCTUnwrap(f.registry.registered.first?.key)
        let menu=try XCTUnwrap(f.session.view.menu(for:event(f)))
        f.session.view.onDown?(.zero,1);f.session.view.onUp?(.zero);XCTAssertNotNil(f.session.interaction.nextClickDeadline)
        status.menuWillOpen(menu);XCTAssertNil(f.session.interaction.nextClickDeadline)
        status.menuWillOpen(status.menu);status.menuDidClose(menu)
        f.registry.emit(id);XCTAssertFalse(f.session.isQuiet)
        status.menuDidClose(status.menu);f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        f.session.play(.idle);f.session.view.onDown?(.zero,1);f.session.view.onMove?(CGPoint(x:20,y:0))
        status.menuWillOpen(menu);XCTAssertFalse(f.session.interaction.isPointerBusy);XCTAssertEqual(f.session.action,.idle)
        status.menuDidClose(menu);XCTAssertNil(f.session.interaction.nextClickDeadline)
    }
    func testContextUnavailableDuringTerminationSheetAndAfterDisposal()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let status=status(f);let event=try event(f)
        XCTAssertNotNil(f.session.view.menu(for:event));status.beginTermination();XCTAssertNil(f.session.view.menu(for:event))
        status.cancelTermination();let menu=try XCTUnwrap(f.session.view.menu(for:event));try invoke("设置…",in:menu)
        let window=try XCTUnwrap(status.settingsController?.window)
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        window.beginSheet(sheet,completionHandler:{_ in});XCTAssertNil(f.session.view.menu(for:event))
        window.endSheet(sheet);sheet.orderOut(nil);XCTAssertNotNil(f.session.view.menu(for:event))
        status.dispose();XCTAssertNil(f.session.view.menu(for:event))
    }
}
