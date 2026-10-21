import AppKit
import XCTest
import PetCore

@MainActor final class QuickSkinMenuTests:XCTestCase {
    private func status(_ f:ShortcutFixture)->StatusBarController {
        StatusBarController(session:f.session,updates:.init(currentVersion:ReleaseVersion(tag:"0.1.14")!,architecture:.arm64,client:NoReleaseRequests()),registry:f.registry,onQuit:{})
    }
    private func context(_ f:ShortcutFixture)throws->NSMenu {
        let event=try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.session.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
        return try XCTUnwrap(f.session.view.menu(for:event))
    }
    private func submenu(_ parent:NSMenu)throws->NSMenu {try XCTUnwrap(parent.items.first{$0.title=="切换皮肤"}?.submenu)}
    private func invoke(_ item:NSMenuItem,in menu:NSMenu){menu.performActionForItem(at:menu.index(of:item))}
    private func wait(_ condition:()->Bool)async {
        for _ in 0..<20000 {if condition(){return};await Task.yield()};XCTFail("Menu work did not settle")
    }
    private func install(_ f:ShortcutFixture,name:String)throws->ImportedSkin {
        let url=try SkinFixtures.writePackage(in:f.directory.appendingPathComponent(UUID().uuidString))
        try SkinFixtures.manifest(["name":name]).write(to:url)
        return try f.session.library.install(SkinLoader.readPackage(manifestURL:url))
    }
    func testBothMenusListImportedSkinsAndSwitchWithoutOpeningSettings()async throws {
        let f=try ShortcutFixture(bindings:[.init(action:.recall,combination:ShortcutFixture.a)]);defer{f.close()}
        let imported=try install(f,name:"Quick character")
        let status=status(f);defer{status.dispose()}
        let bar=try submenu(status.menu),right=try submenu(context(f))
        status.menuWillOpen(status.menu)
        await wait{bar.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        XCTAssertNil(status.settingsController)
        let item=try XCTUnwrap(bar.items.first{$0.representedObject as? String==imported.id})
        let before=f.session.preferences
        status.menuDidClose(status.menu);invoke(item,in:bar)
        await wait{f.session.selectedSkinID==imported.id && right.items.contains{$0.representedObject as? String==imported.id && $0.state == .on}}
        XCTAssertNil(status.settingsController);XCTAssertEqual(f.session.preferences,before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.session.library.directory.path).count,1)
        guard case .loaded(let saved)=SettingsStore(url:f.settingsURL).load() else{return XCTFail("selection missing")}
        XCTAssertEqual(saved.selectedSkinID,imported.id);XCTAssertEqual(saved.preferences,before)
        let defaultItem=try XCTUnwrap(right.items.first{$0.representedObject as? String=="default"})
        await wait{defaultItem.isEnabled};invoke(defaultItem,in:right)
        await wait{f.session.selectedSkinID==nil && defaultItem.state == .on}
        XCTAssertEqual(f.session.skin.directory,f.session.defaultSkin.directory)
    }
    func testBrokenEntriesAreDisabledAndManageOpensSkinGroup()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let broken=try install(f,name:"Broken")
        try Data("broken".utf8).write(to:f.session.library.directory.appendingPathComponent(broken.id).appendingPathComponent("pet.json"))
        let status=status(f);defer{status.dispose()}
        let menu=try submenu(status.menu)
        status.menuWillOpen(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==broken.id}}
        let bad=try XCTUnwrap(menu.items.first{$0.representedObject as? String==broken.id})
        XCTAssertFalse(bad.isEnabled);XCTAssertNotNil(bad.toolTip)
        status.menuDidClose(status.menu)
        let manage=try XCTUnwrap(menu.items.first{$0.title=="管理皮肤…"});invoke(manage,in:menu)
        XCTAssertEqual(status.settingsController?.model.selectedTab,.skin);XCTAssertTrue(status.settingsController?.window?.isVisible==true)
    }
    func testStaleEntrySaveFailurePreservesCurrentPetAndShowsError()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let imported=try install(f,name:"Other")
        let status=status(f);defer{status.dispose()};let menu=try submenu(status.menu)
        status.menuWillOpen(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        let entry=try XCTUnwrap(menu.items.first{$0.representedObject as? String==imported.id}),original=f.session.skin.directory
        status.menuDidClose(status.menu);f.input.writeFails=true;invoke(entry,in:menu)
        await wait{menu.items.contains{$0.title.contains("失败")}}
        XCTAssertEqual(f.session.skin.directory,original);XCTAssertNil(f.session.selectedSkinID)
        f.input.writeFails=false
        let error=try XCTUnwrap(menu.items.first{$0.title.contains("失败") && $0.action != nil});invoke(error,in:menu)
        XCTAssertNotNil(status.settingsController?.model.skinError)
    }
    func testSharedModelRefreshesAfterApplicationLoadsSavedSettings()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let preferences=PetPreferences(scale:1.5,lookAtMouse:false,positionLocked:true)
        try SettingsStore(url:f.settingsURL).save(.init(placement:nil,preferences:preferences))
        let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.settingsURL),screens:f.session.screens)
        let status=StatusBarController(session:reopened,registry:f.registry,onQuit:{});defer{status.dispose();reopened.prepareToExit()}
        reopened.start();XCTAssertNil(status.settingsController)
        XCTAssertEqual(status.skinModel?.preferences,preferences)
    }
    func testNamesThatDisplayIdenticallyRemainDistinct()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let a=try install(f,name:"Same  Skin"),b=try install(f,name:"Same Skin")
        let status=status(f);defer{status.dispose()};let menu=try submenu(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==a.id} && menu.items.contains{$0.representedObject as? String==b.id}}
        let titles=menu.items.filter{[a.id,b.id].contains($0.representedObject as? String ?? "")}.map(\.title)
        XCTAssertEqual(Set(titles).count,2);XCTAssertTrue(titles.allSatisfy{!$0.contains("\n")})
    }
    func testModalTerminationAndOverlappingSubmenuGates()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let imported=try install(f,name:"Other"),status=status(f);defer{status.dispose()};status.startShortcuts()
        let menu=try submenu(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        let entry=try XCTUnwrap(menu.items.first{$0.representedObject as? String==imported.id})
        status.shortcuts?.apply(ShortcutFixture.a,to:.toggleQuiet);let id=try XCTUnwrap(f.registry.registered.first?.key)
        status.menuWillOpen(status.menu);status.menuWillOpen(menu);status.menuDidClose(status.menu)
        f.registry.emit(id);XCTAssertFalse(f.session.isQuiet);status.menuDidClose(menu)
        f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        let manage=try XCTUnwrap(menu.items.first{$0.title=="管理皮肤…"});invoke(manage,in:menu)
        let window=try XCTUnwrap(status.settingsController?.window)
        XCTAssertTrue(status.skinModel === status.settingsController?.model)
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        window.beginSheet(sheet,completionHandler:{_ in});defer{window.endSheet(sheet);sheet.orderOut(nil)}
        _=NSApp.sendAction(try XCTUnwrap(entry.action),to:entry.target,from:entry)
        await Task.yield();XCTAssertNil(f.session.selectedSkinID)
        window.endSheet(sheet);sheet.orderOut(nil);status.beginTermination()
        _=NSApp.sendAction(try XCTUnwrap(entry.action),to:entry.target,from:entry)
        await Task.yield();XCTAssertNil(f.session.selectedSkinID)
    }
    func testVanishedCachedSkinLeavesCurrentPetAndReportsFailure()async throws {
        let f=try ShortcutFixture();defer{f.close()}
        let imported=try install(f,name:"Vanished"),status=status(f);defer{status.dispose()};let menu=try submenu(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        let entry=try XCTUnwrap(menu.items.first{$0.representedObject as? String==imported.id}),old=f.session.skin.directory
        try f.session.library.remove(id:imported.id);invoke(entry,in:menu)
        await wait{menu.items.contains{$0.title.contains("失败")}}
        XCTAssertEqual(f.session.skin.directory,old);XCTAssertNil(f.session.selectedSkinID)
    }
    func testBusyPreviewBlocksSwitchAndNormalTerminationWaits()async throws {
        let f=try ShortcutFixture();defer{f.close()};let imported=try install(f,name:"Other")
        let started=expectation(description:"background preview held"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=SettingsModel(session:f.session,previewPackage:{url in
            let package=try SkinLoader.readPackage(manifestURL:url);started.fulfill();release.wait();return package
        })
        let menus=QuickSkinMenus(session:f.session,model:model,canDispatch:{true},onManage:{});defer{menus.dispose()}
        let menu=menus.menus[0]
        await wait{menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        let item=try XCTUnwrap(menu.items.first{$0.representedObject as? String==imported.id})
        let preview=Task{await model.previewSkin(at:f.directory.appendingPathComponent("pet.json"))}
        let result=await XCTWaiter.fulfillment(of:[started],timeout:5);XCTAssertEqual(result,.completed)
        XCTAssertFalse(item.isEnabled);XCTAssertTrue(model.hasPendingMutation)
        _=NSApp.sendAction(try XCTUnwrap(item.action),to:item.target,from:item);await Task.yield();XCTAssertNil(f.session.selectedSkinID)
        model.beginTermination();menus.cancel()
        var completed=false;let waiting=Task{await model.waitForPendingMutations();completed=true}
        await Task.yield();XCTAssertFalse(completed)
        release.signal();await preview.value;await waiting.value
        XCTAssertNil(model.candidate);XCTAssertNil(f.session.selectedSkinID);XCTAssertTrue(completed)
    }
    func testListReadFailureKeepsCacheAndRetryRecovers()async throws {
        let f=try ShortcutFixture();defer{f.close()};let imported=try install(f,name:"Other"),status=status(f);defer{status.dispose()}
        let menu=try submenu(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        let held=f.directory.appendingPathComponent("held-library"),library=f.session.library.directory
        try FileManager.default.moveItem(at:library,to:held);try Data("unavailable".utf8).write(to:library)
        status.menuWillOpen(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String=="list-error" && $0.isEnabled}}
        XCTAssertTrue(menu.items.contains{$0.representedObject as? String==imported.id})
        try FileManager.default.removeItem(at:library);try FileManager.default.moveItem(at:held,to:library)
        let retry=try XCTUnwrap(menu.items.first{$0.representedObject as? String=="list-error"});invoke(retry,in:menu)
        await wait{status.skinModel?.libraryError==nil && menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        status.menuDidClose(status.menu)
    }
    func testProtectedConfigAndCancelledQueuedSwitchDoNotChangeSelection()async throws {
        let f=try ShortcutFixture(corrupt:true);defer{f.close()};let imported=try install(f,name:"Other"),status=status(f);defer{status.dispose()}
        let menu=try submenu(status.menu)
        await wait{menu.items.contains{$0.representedObject as? String==imported.id}}
        let item=try XCTUnwrap(menu.items.first{$0.representedObject as? String==imported.id}),bytes=try Data(contentsOf:f.settingsURL)
        XCTAssertFalse(item.isEnabled);_ = NSApp.sendAction(try XCTUnwrap(item.action),to:item.target,from:item)
        await Task.yield();XCTAssertNil(f.session.selectedSkinID);XCTAssertEqual(try Data(contentsOf:f.settingsURL),bytes)
        f.session.resetProtectedSettings();await wait{item.isEnabled}
        invoke(item,in:menu);status.beginTermination()
        for _ in 0..<30{await Task.yield()};XCTAssertNil(f.session.selectedSkinID)
    }
    func testCachedChoiceWinsOverQueuedMenuRefresh()async throws {
        let f=try ShortcutFixture();defer{f.close()};let imported=try install(f,name:"Other")
        let model=SettingsModel(session:f.session);await model.reloadLibrary()
        let menus=QuickSkinMenus(session:f.session,model:model,canDispatch:{true},onManage:{});defer{menus.dispose()}
        let menu=menus.menus[0],entry=try XCTUnwrap(menus.menus[0].items.first{$0.representedObject as? String==imported.id})
        XCTAssertTrue(entry.isEnabled);invoke(entry,in:menu)
        await wait{f.session.selectedSkinID==imported.id}
    }
    private func confirmedChoiceClosingSettings(terminating:Bool)async throws {
        let f=try ShortcutFixture();defer{f.close()};let imported=try install(f,name:"Other")
        let started=expectation(description:"confirmed menu skin load held"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=SettingsModel(session:f.session,loadSkin:{library,id in
            let skin=try library.load(id:id);started.fulfill();release.wait();return skin
        })
        let menus=QuickSkinMenus(session:f.session,model:model,canDispatch:{true},onManage:{});defer{menus.dispose()}
        let updates=ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:"0.1.14")!,architecture:.arm64,client:NoReleaseRequests())
        let window=SettingsWindowController(session:f.session,updates:updates,shortcuts:f.controller,model:model);defer{window.close()}
        window.present(tab:.general)
        let menu=menus.menus[0]
        await wait{menu.items.contains{$0.representedObject as? String==imported.id && $0.isEnabled}}
        invoke(try XCTUnwrap(menu.items.first{$0.representedObject as? String==imported.id}),in:menu)
        let result=await XCTWaiter.fulfillment(of:[started],timeout:5);XCTAssertEqual(result,.completed)
        window.close();XCTAssertTrue(model.hasPendingMutation)
        if terminating{model.beginTermination();menus.cancel()}
        release.signal();await model.waitForPendingMutations()
        XCTAssertEqual(f.session.selectedSkinID,terminating ? nil : imported.id)
    }
    func testConfirmedMenuChoiceSurvivesSettingsClosing()async throws {try await confirmedChoiceClosingSettings(terminating:false)}
    func testConfirmedMenuChoiceStillCancelsOnTermination()async throws {try await confirmedChoiceClosingSettings(terminating:true)}
}
