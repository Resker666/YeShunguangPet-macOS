import AppKit
import XCTest
import PetCore

@MainActor private final class FocusInput {var time=Duration.zero;var failWrites=false}
@MainActor final class FocusCompanionTests:XCTestCase {
    @MainActor private struct Fixture {
        let directory:URL,session:PetSession,input:FocusInput,focus:FocusController
        func close(){focus.dispose();session.prepareToExit();try? FileManager.default.removeItem(at:directory)}
    }
    private func fixture()throws->Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),input=FocusInput()
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("skin"))
        try SkinFixtures.manifest(["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["durationsMs":[1000],"loop":false],"jumping":["durationsMs":[1000],"loop":false]]]).write(to:manifest)
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{data,url in
            if input.failWrites{throw SkinError("injected write failure")};try data.write(to:url,options:.atomic)
        })
        try store.save(.init(placement:nil,preferences:.init(alwaysOnTop:false,lookAtMouse:false,speechEnabled:true,positionLocked:true,focusMinutes:1,breakMinutes:1)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{[.init(id:"test",visibleFrame:CGRect(x:0,y:0,width:1200,height:900),isPrimary:true)]})
        session.start();session.panel.setFrameOrigin(CGPoint(x:200,y:200))
        return .init(directory:directory,session:session,input:input,focus:FocusController(session:session))
    }
    private func bubbleText(_ session:PetSession)->String? {
        session.panel.childWindows?.first{$0.title=="角色台词" && $0.isVisible}?.contentView?.subviews.compactMap{$0 as? NSTextField}.first?.stringValue
    }
    func testHiddenFocusKeepsDeadlineAndCompletesOnlyOnceWithoutShowingPet()throws {
        let f=try fixture();defer{f.close()}
        var completions=0;f.focus.onChange={completions+=1}
        f.focus.startOrResume();XCTAssertTrue(f.session.focusQuiet);XCTAssertFalse(f.session.isQuiet)
        f.session.setVisible(false);f.input.time = .seconds(60);f.focus.refreshTime()
        XCTAssertEqual(f.focus.status,.completed);XCTAssertEqual(f.focus.phase,.focus);XCTAssertEqual(f.focus.remainingSeconds,0)
        XCTAssertFalse(f.session.isVisible);XCTAssertFalse(f.session.focusQuiet);XCTAssertEqual(f.focus.scheduler.pendingCount,0)
        let settled=completions;f.focus.refreshTime();f.focus.setSleeping(false)
        XCTAssertEqual(completions,settled);XCTAssertNil(bubbleText(f.session))
        f.session.setVisible(true);f.session.tick();XCTAssertNil(bubbleText(f.session))
    }
    func testManualQuietSurvivesPauseCompletionAndReset()throws {
        let f=try fixture();defer{f.close()};f.session.setQuiet(true)
        f.focus.startOrResume();f.input.time = .seconds(20);f.focus.pause()
        XCTAssertTrue(f.session.isQuiet);XCTAssertFalse(f.session.focusQuiet);XCTAssertEqual(f.focus.remainingSeconds,40)
        f.input.time = .seconds(100);f.focus.startOrResume();f.input.time = .seconds(140);f.focus.refreshTime()
        XCTAssertTrue(f.session.isQuiet);XCTAssertNil(bubbleText(f.session));f.focus.reset();XCTAssertTrue(f.session.isQuiet)
    }
    func testLatePauseAndStaleStartCannotBeginNextPhase()throws {
        for pause in [true,false] {
            let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(60)
            if pause{f.focus.pause()}else{f.focus.startOrResume()}
            XCTAssertEqual(f.focus.status,.completed);XCTAssertEqual(f.focus.phase,.focus)
            f.focus.startOrResume();XCTAssertEqual(f.focus.phase,.rest);XCTAssertEqual(f.focus.status,.running)
            XCTAssertFalse(f.session.focusQuiet)
        }
    }
    func testNewPreferencesCommitBeforeBecomingEffectiveAndCannotBypass()throws {
        let f=try fixture();defer{f.close()};let old=f.session.preferences
        var bypass=old;bypass.focusMinutes=90;bypass.speechOverrides=[f.session.skin.manifest.id:.defaults]
        f.session.setPreferences(bypass);XCTAssertEqual(f.session.preferences,old)
        f.input.failWrites=true
        XCTAssertThrowsError(try f.focus.applyDurations(focusMinutes:30,breakMinutes:10))
        XCTAssertThrowsError(try f.session.saveSpeechOverrides([f.session.skin.manifest.id:.defaults]))
        XCTAssertEqual(f.session.preferences,old);XCTAssertEqual(f.focus.remainingSeconds,60)
        f.input.failWrites=false;try f.focus.applyDurations(focusMinutes:30,breakMinutes:10)
        let personal=SpeechLines(click:["个人点击"],drag:[],focusCompleted:["个人专注结束"],breakCompleted:["个人休息结束"])
        try f.session.saveSpeechOverrides([f.session.skin.manifest.id:personal])
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("new prefs must persist")}
        XCTAssertEqual(saved.preferences.focusMinutes,30);XCTAssertEqual(saved.preferences.breakMinutes,10)
        XCTAssertEqual(saved.preferences.speechOverrides[f.session.skin.manifest.id],personal);XCTAssertTrue(saved.preferences.positionLocked)
        XCTAssertFalse(saved.preferences.alwaysOnTop)
    }
    func testCompletionUsesCurrentPersonalSpeechAndBypassesClickCooldown()throws {
        let f=try fixture();defer{f.close()}
        try f.session.saveSpeechOverrides([f.session.skin.manifest.id:.init(click:["点击"],drag:["拖动"],focusCompleted:["专注结束"],breakCompleted:["休息结束"])])
        f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime()
        XCTAssertEqual(bubbleText(f.session),"专注结束");XCTAssertEqual(f.session.action,.waving)
        f.focus.startOrResume();f.input.time = .seconds(119)
        f.session.view.onDown?(.zero,1);f.session.view.onUp?(.zero);f.input.time = .seconds(120);f.session.tick()
        XCTAssertEqual(bubbleText(f.session),"点击")
        f.input.time = .seconds(122);f.session.tick();f.focus.refreshTime()
        XCTAssertEqual(f.focus.phase,.rest);XCTAssertEqual(f.focus.status,.completed)
        XCTAssertEqual(bubbleText(f.session),"休息结束");XCTAssertEqual(f.session.action,.jumping)
        let bubble=try XCTUnwrap(f.session.panel.childWindows?.first{$0.title=="角色台词" && $0.isVisible})
        XCTAssertFalse(bubble.canBecomeKey);XCTAssertTrue(bubble.ignoresMouseEvents)
    }
    func testSleepAndCancelledTerminationReconcileOneOriginalDeadline()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.focus.setSleeping(true)
        XCTAssertEqual(f.focus.scheduler.pendingCount,0);f.input.time = .seconds(80);f.focus.setSleeping(false)
        XCTAssertEqual(f.focus.status,.completed)
        f.focus.reset();f.focus.startOrResume();f.focus.setTerminating(true)
        XCTAssertEqual(f.focus.scheduler.pendingCount,0);f.input.time = .seconds(200)
        f.focus.startOrResume();XCTAssertEqual(f.focus.status,.running)
        f.focus.setTerminating(false);XCTAssertEqual(f.focus.status,.completed);f.focus.dispose();XCTAssertEqual(f.focus.scheduler.pendingCount,0)
    }
    func testMenuSettingsAndPointerBlockCompletionWithoutReplay()throws {
        for blocker in ["menu","settings","pointer"] {
            let f=try fixture();defer{f.close()};f.focus.startOrResume()
            if blocker=="menu"{f.session.setMenuOpen(true)}else if blocker=="settings"{f.session.setSettingsOpen(true)}else{f.session.view.onDown?(.zero,1)}
            f.input.time = .seconds(60);f.focus.refreshTime();XCTAssertNil(bubbleText(f.session),blocker)
            f.session.setMenuOpen(false);f.session.setSettingsOpen(false);f.session.cancelInput();f.session.tick();XCTAssertNil(bubbleText(f.session),blocker)
            XCTAssertEqual(f.focus.status,.completed)
        }
    }
    func testDisplayConsumersDoNotCreateMultipleTimersAndDisposeStopsAll()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume()
        XCTAssertEqual(f.focus.scheduler.pendingCount,1)
        XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(60))
        f.focus.setDisplayVisible(true,source:"settings");f.focus.setDisplayVisible(true,source:"menu")
        XCTAssertEqual(f.focus.scheduler.pendingCount,1)
        XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(1))
        f.focus.setDisplayVisible(false,source:"menu");f.focus.setDisplayVisible(false,source:"settings")
        XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(60))
        XCTAssertEqual(f.focus.scheduler.pendingCount,1);f.focus.pause();XCTAssertEqual(f.focus.scheduler.pendingCount,0)
        f.focus.dispose();XCTAssertFalse(f.session.focusQuiet)
    }
    func testSkinChangeAndOtherPreferencesPreserveActiveFocusAndPersonalSpeech()throws {
        let f=try fixture();defer{f.close()};try f.session.saveSpeechOverrides([f.session.skin.manifest.id:.defaults])
        f.focus.startOrResume();f.input.time = .seconds(10);try f.session.restoreDefaultSkin()
        var preferences=f.session.preferences;preferences.scale=1.5;preferences.snapToEdges=true;f.session.setPreferences(preferences)
        f.focus.refreshTime();XCTAssertEqual(f.focus.remainingSeconds,50);XCTAssertTrue(f.session.focusQuiet)
        XCTAssertTrue(f.session.preferences.positionLocked);XCTAssertEqual(f.session.preferences.speechOverrides.count,1)
    }
    func testBothNativeFocusMenusAndDedicatedSettingsTabExistWithoutOpeningSettings()throws {
        let f=try fixture();defer{f.close()}
        let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
        let bar=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        let right=try XCTUnwrap(f.session.view.contextMenu?()?.items.first{$0.title=="专注计时"}?.submenu)
        XCTAssertFalse(bar === right);XCTAssertEqual(SettingsTab.allCases.count,6)
        XCTAssertNotNil(bar.items.first{$0.title=="开始专注"});XCTAssertNotNil(right.items.first{$0.title=="专注设置…"})
        XCTAssertNil(status.settingsController)
    }
    func testMenusShareTimerAndClosingSettingsKeepsItRunning()throws {
        let f=try fixture();defer{f.close()}
        let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
        let focus=try XCTUnwrap(status.focus),bar=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        let right=try XCTUnwrap(f.session.view.contextMenu?()?.items.first{$0.title=="专注计时"}?.submenu)
        status.menuWillOpen(status.menu);status.menuWillOpen(bar)
        XCTAssertEqual(focus.scheduler.pendingCount,0)
        status.menuDidClose(bar);status.menuDidClose(status.menu)
        bar.performActionForItem(at:try XCTUnwrap(bar.items.firstIndex{$0.title=="开始专注"}))
        XCTAssertEqual(focus.status,.running);XCTAssertTrue(f.session.focusQuiet)
        XCTAssertTrue(right.items.contains{$0.title=="暂停专注"})
        status.menuWillOpen(status.menu);status.menuWillOpen(bar)
        XCTAssertEqual(focus.scheduler.scheduledDeadline,.seconds(1))
        status.menuDidClose(status.menu);XCTAssertEqual(focus.scheduler.scheduledDeadline,.seconds(1))
        status.menuDidClose(bar);XCTAssertEqual(focus.scheduler.scheduledDeadline,.seconds(60))
        bar.performActionForItem(at:try XCTUnwrap(bar.items.firstIndex{$0.title=="专注设置…"}))
        let window=try XCTUnwrap(status.settingsController)
        XCTAssertTrue(window.model.focus === focus);XCTAssertEqual(window.model.selectedTab,.focus)
        XCTAssertEqual(focus.scheduler.scheduledDeadline,.seconds(1));window.close()
        XCTAssertEqual(focus.status,.running);XCTAssertEqual(focus.scheduler.scheduledDeadline,.seconds(60))
        f.input.time = .seconds(60);focus.refreshTime();XCTAssertEqual(focus.status,.completed)
        status.beginTermination();let item=try XCTUnwrap(bar.items.first{$0.title=="开始休息"})
        XCTAssertFalse(item.isEnabled);bar.performActionForItem(at:bar.index(of:item));XCTAssertEqual(focus.status,.completed)
        status.cancelTermination();XCTAssertTrue(item.isEnabled)
    }
    func testPersonalDraftTargetGenerationAndFailuresCannotChangeAnotherRole()throws {
        let f=try fixture();defer{f.close()};let model=SettingsModel(session:f.session)
        let id=f.session.skin.manifest.id,original=model.speechEditGeneration
        let lines=SpeechLines(click:["个人"],drag:[],focusCompleted:["结束"],breakCompleted:[])
        f.input.failWrites=true
        XCTAssertThrowsError(try model.applyPersonalSpeech(lines,for:id,generation:original));XCTAssertTrue(f.session.preferences.speechOverrides.isEmpty)
        f.input.failWrites=false;try model.applyPersonalSpeech(lines,for:id,generation:original)
        XCTAssertEqual(f.session.preferences.speechOverrides[id],lines)
        let savedGeneration=model.speechEditGeneration;model.selectedTab = .interaction;model.selectedTab = .focus
        XCTAssertGreaterThan(model.speechEditGeneration,savedGeneration)
        XCTAssertThrowsError(try model.applyPersonalSpeech(.defaults,for:id,generation:savedGeneration))
        let other=try SkinFixtures.writePackage(in:f.directory.appendingPathComponent("other"))
        try SkinFixtures.manifest(["id":"other-role","name":"Other role"]).write(to:other)
        let imported=try f.session.library.install(SkinLoader.readPackage(manifestURL:other))
        let oldGeneration=model.speechEditGeneration
        try f.session.useImportedSkin(imported);model.refresh()
        XCTAssertThrowsError(try model.applyPersonalSpeech(.defaults,for:id,generation:oldGeneration))
        XCTAssertNil(f.session.preferences.speechOverrides["other-role"])
        try model.removePersonalSpeech(for:id);XCTAssertTrue(f.session.preferences.speechOverrides.isEmpty)
    }
    func testClosingWindowInvalidatesSpeechDraftAndTerminationBlocksCommit()throws {
        let f=try fixture();defer{f.close()}
        let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
        let bar=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        bar.performActionForItem(at:try XCTUnwrap(bar.items.firstIndex{$0.title=="专注设置…"}))
        let window=try XCTUnwrap(status.settingsController),model=window.model
        model.selectedTab = .interaction;let generation=model.speechEditGeneration
        window.close();XCTAssertGreaterThan(model.speechEditGeneration,generation)
        XCTAssertThrowsError(try model.applyPersonalSpeech(.defaults,for:f.session.skin.manifest.id,generation:generation))
        model.beginTermination()
        XCTAssertThrowsError(try model.removePersonalSpeech(for:f.session.skin.manifest.id))
    }
    func testPendingSkinPreviewRejectsPersonalSpeechChanges()async throws {
        let f=try fixture();defer{f.close()}
        let started=expectation(description:"preview held"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=SettingsModel(session:f.session,previewPackage:{url in
            let package=try SkinLoader.readPackage(manifestURL:url);started.fulfill();release.wait();return package
        })
        let generation=model.speechEditGeneration,id=f.session.skin.manifest.id
        let task=Task {await model.previewSkin(at:f.session.skin.directory.appendingPathComponent("pet.json"))}
        let wait=await XCTWaiter.fulfillment(of:[started],timeout:5);XCTAssertEqual(wait,.completed)
        XCTAssertTrue(model.isBusy);XCTAssertThrowsError(try model.applyPersonalSpeech(.defaults,for:id,generation:generation))
        XCTAssertThrowsError(try model.removePersonalSpeech(for:id));XCTAssertTrue(f.session.preferences.speechOverrides.isEmpty)
        model.cancelSkinSelection();release.signal();await task.value
    }
    func testFocusModalBlocksEvenDirectMenuAction()throws {
        let f=try fixture();defer{f.close()}
        let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
        let bar=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        bar.performActionForItem(at:try XCTUnwrap(bar.items.firstIndex{$0.title=="专注设置…"}))
        let window=try XCTUnwrap(status.settingsController?.window)
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        window.beginSheet(sheet,completionHandler:{_ in});defer{window.endSheet(sheet);sheet.orderOut(nil)}
        status.menuWillOpen(bar)
        let item=try XCTUnwrap(bar.items.first{$0.title=="开始专注"});XCTAssertFalse(item.isEnabled)
        _=NSApp.sendAction(try XCTUnwrap(item.action),to:item.target,from:item)
        XCTAssertEqual(status.focus?.status,.ready);status.menuDidClose(bar)
    }
    func testFocusSubmenuSuppressesShortcutsUntilLastParentCloses()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let status=StatusBarController(session:f.session,registry:f.registry,onQuit:{});defer{status.dispose()};status.startShortcuts()
        status.shortcuts?.apply(ShortcutFixture.a,to:.toggleQuiet)
        let id=try XCTUnwrap(f.registry.registered.first?.key),bar=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        status.menuWillOpen(status.menu);status.menuWillOpen(bar);status.menuDidClose(status.menu)
        f.registry.emit(id);XCTAssertFalse(f.session.isQuiet);status.menuDidClose(bar)
        f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
    }
    func testProtectedConfigurationStillAllowsDefaultTimerButNeverPersistsNewValues()throws {
        let f=try fixture();defer{f.close()}
        let url=f.directory.appendingPathComponent("protected.json"),bad=Data("{broken".utf8);try bad.write(to:url)
        let session=PetSession(skin:f.session.skin,now:{f.input.time},settings:SettingsStore(url:url),screens:f.session.screens)
        session.start();let focus=FocusController(session:session);defer{focus.dispose();session.prepareToExit()}
        XCTAssertTrue(session.protectedSettings);focus.startOrResume();XCTAssertEqual(focus.remainingSeconds,1500)
        focus.reset();XCTAssertThrowsError(try focus.applyDurations(focusMinutes:1,breakMinutes:1))
        XCTAssertThrowsError(try session.saveSpeechOverrides([session.skin.manifest.id:.defaults]))
        XCTAssertEqual(try Data(contentsOf:url),bad)
    }
    func testRenderedPauseCannotStartNextPhaseWhenCompletionWasAlreadyDelivered()throws {
        for reconcileFirst in [false,true] {
            let f=try fixture();defer{f.close()}
            let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
            let focus=try XCTUnwrap(status.focus),menu=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
            focus.startOrResume();let oldPause=try XCTUnwrap(menu.items.first{$0.title=="暂停专注"})
            f.input.time = .seconds(60)
            if reconcileFirst{focus.refreshTime()}
            _=NSApp.sendAction(try XCTUnwrap(oldPause.action),to:oldPause.target,from:oldPause)
            XCTAssertEqual(focus.status,.completed,"completion-first=\(reconcileFirst)")
            XCTAssertEqual(focus.phase,.focus,"An old pause must never start rest")
        }
    }
    func testCancelledTerminationRestoresOnlyVisibleFocusDisplayConsumer()throws {
        for visibility in ["focus","other","closed"] {
            let f=try fixture();defer{f.close()}
            let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
            let focus=try XCTUnwrap(status.focus),menu=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
            menu.performActionForItem(at:try XCTUnwrap(menu.items.firstIndex{$0.title=="专注设置…"}))
            let window=try XCTUnwrap(status.settingsController)
            if visibility=="other"{window.model.selectedTab = .interaction}else if visibility=="closed"{window.close()}
            focus.startOrResume();f.input.time = .seconds(10);status.beginTermination()
            XCTAssertNil(focus.scheduler.scheduledDeadline)
            status.cancelTermination()
            XCTAssertEqual(focus.scheduler.scheduledDeadline,visibility=="focus" ? .seconds(11) : .seconds(60),visibility)
            XCTAssertEqual(focus.status,.running)
        }
    }
    func testCapturedViewCommandCannotBeReinterpretedAfterTransition()throws {
        let f=try fixture();defer{f.close()}
        f.focus.startOrResume();let pause=f.focus.primaryCommand
        f.input.time = .seconds(60);f.focus.refreshTime();f.focus.perform(pause)
        XCTAssertEqual(f.focus.status,.completed);XCTAssertEqual(f.focus.phase,.focus)
        let startRest=f.focus.primaryCommand;f.focus.perform(startRest)
        XCTAssertEqual(f.focus.status,.running);XCTAssertEqual(f.focus.phase,.rest)
        f.focus.perform(startRest);XCTAssertEqual(f.focus.status,.running)
        f.focus.reset();f.focus.perform(pause);XCTAssertEqual(f.focus.status,.ready)
    }
}
