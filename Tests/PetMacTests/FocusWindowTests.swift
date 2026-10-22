import AppKit
import XCTest
import PetCore

@MainActor private final class FocusWindowInput {
    var time=Duration.zero,failWrites=false,blocked=false
    var writes=0
    var screens=[ScreenArea(id:"main",visibleFrame:CGRect(x:0,y:0,width:1200,height:900),isPrimary:true)]
}
@MainActor final class FocusWindowTests:XCTestCase {
    @MainActor private struct Fixture {
        let directory:URL,session:PetSession,focus:FocusController,window:FocusWindowController,input:FocusWindowInput
        func close(){window.dispose();focus.dispose();session.prepareToExit();try? FileManager.default.removeItem(at:directory)}
    }
    private func fixture()throws->Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),input=FocusWindowInput()
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("skin"))
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{data,url in
            if input.failWrites{throw SkinError("injected failure")};input.writes+=1;try data.write(to:url,options:.atomic)
        })
        try store.save(.init(placement:nil,preferences:.init(lookAtMouse:false,focusMinutes:1,breakMinutes:1)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{input.screens})
        session.start();let focus=FocusController(session:session)
        let window=FocusWindowController(session:session,focus:focus,canDispatch:{!input.blocked})
        window.start();return .init(directory:directory,session:session,focus:focus,window:window,input:input)
    }
    private func click(_ button:NSButton)throws {XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action),to:button.target,from:button))}
    func testCompactModePreservesTopLeftAndCountdownAndRestoresAfterRestart()throws {
        let f=try fixture();defer{f.close()};f.window.panel.setFrameOrigin(CGPoint(x:200,y:200));f.window.finishDrag()
        let pet=f.session.panel.frame,writes=f.input.writes;f.focus.startOrResume();f.input.time = .seconds(12);f.focus.refreshTime()
        f.window.setCompact(true)
        XCTAssertEqual(f.window.panel.frame,CGRect(x:200,y:296,width:200,height:112));XCTAssertEqual(f.input.writes,writes+1)
        XCTAssertEqual(f.window.timeLabel.stringValue,"00:48");XCTAssertEqual(f.session.panel.frame,pet)
        XCTAssertTrue(f.session.preferences.focusWindow.compact)
        let another=FocusWindowController(session:f.session,focus:f.focus,canDispatch:{true});defer{another.dispose()};f.window.dispose();another.start()
        XCTAssertEqual(another.panel.frame,CGRect(x:200,y:296,width:200,height:112))
        another.setCompact(false);XCTAssertEqual(another.panel.frame,CGRect(x:200,y:200,width:280,height:208));XCTAssertEqual(f.focus.remainingSeconds,48)
    }
    func testCompactExpansionClampsToScreenAndKeepsHiddenState()throws {
        let f=try fixture();defer{f.close()};f.window.setCompact(true);f.window.setVisible(false)
        f.window.panel.setFrameOrigin(CGPoint(x:1000,y:0));f.window.finishDrag();f.window.setCompact(false)
        XCTAssertTrue(f.input.screens[0].visibleFrame.contains(f.window.panel.frame));XCTAssertFalse(f.window.panel.isVisible)
        XCTAssertFalse(f.session.preferences.focusWindow.isVisible)
    }
    func testCompactSaveFailureLeavesTemporaryModeAndCanRetry()throws {
        let f=try fixture();defer{f.close()};let bytes=try Data(contentsOf:f.session.settings.url)
        f.input.failWrites=true;f.window.setCompact(true)
        XCTAssertEqual(f.window.panel.frame.size,CGSize(width:200,height:112));XCTAssertNotNil(f.window.lastSaveError)
        XCTAssertFalse(f.session.preferences.focusWindow.compact);XCTAssertEqual(try Data(contentsOf:f.session.settings.url),bytes)
        f.window.refreshPreferences();XCTAssertTrue(f.window.configuration.compact)
        f.input.failWrites=false;f.window.retrySave();XCTAssertTrue(f.session.preferences.focusWindow.compact)
    }
    func testCompactToggleFromMenusAndHeaderRespectsModalAndExit()throws {
        let f=try fixture();defer{f.close()}
        let menus=FocusMenus(focus:f.focus,desktop:f.window,canDispatch:{!f.input.blocked},onSettings:{});defer{menus.dispose()}
        let item=try XCTUnwrap(menus.menus[0].items.first{$0.title=="紧凑计时窗"})
        menus.menus[0].performActionForItem(at:try XCTUnwrap(menus.menus[0].items.firstIndex(of:item)))
        XCTAssertTrue(f.window.configuration.compact);XCTAssertEqual(item.state,.on)
        f.input.blocked=true;try click(f.window.modeButton);XCTAssertTrue(f.window.configuration.compact)
        f.input.blocked=false;f.window.beginTermination();try click(f.window.modeButton);XCTAssertTrue(f.window.configuration.compact)
        f.window.cancelTermination();try click(f.window.modeButton);XCTAssertFalse(f.window.configuration.compact)
    }
    func testCompletionHighlightPersistsAcrossModesUntilNextPhaseOrReset()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime()
        XCTAssertTrue(f.window.isCompletionHighlighted);f.window.setCompact(true);XCTAssertTrue(f.window.isCompletionHighlighted)
        f.window.setVisible(false);f.window.setVisible(true);XCTAssertTrue(f.window.isCompletionHighlighted)
        try click(f.window.primaryButton);XCTAssertFalse(f.window.isCompletionHighlighted)
        f.input.time = .seconds(120);f.focus.refreshTime();XCTAssertTrue(f.window.isCompletionHighlighted)
        f.focus.reset();XCTAssertFalse(f.window.isCompletionHighlighted)
    }
    func testModeChangeCancelsExistingGestureAndCompactHeaderCanStartFreshDrag()throws {
        let f=try fixture();defer{f.close()}
        let header=try XCTUnwrap(f.window.panel.contentView?.hitTest(CGPoint(x:140,y:190)))
        func event(_ type:NSEvent.EventType,_ point:CGPoint)throws->NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:f.window.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0))
        }
        header.mouseDown(with:try event(.leftMouseDown,CGPoint(x:140,y:190)));f.window.setCompact(true)
        let origin=f.window.panel.frame.origin,writes=f.input.writes
        header.mouseUp(with:try event(.leftMouseUp,CGPoint(x:100,y:100)))
        XCTAssertEqual(f.window.panel.frame.origin,origin);XCTAssertEqual(f.input.writes,writes)
        let compactHeader=try XCTUnwrap(f.window.panel.contentView?.hitTest(CGPoint(x:85,y:98)))
        compactHeader.mouseDown(with:try event(.leftMouseDown,CGPoint(x:85,y:98)))
        compactHeader.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:65,y:88)))
        XCTAssertEqual(f.input.writes,writes)
        compactHeader.mouseUp(with:try event(.leftMouseUp,CGPoint(x:85,y:98)))
        XCTAssertEqual(f.input.writes,writes+1);XCTAssertEqual(f.window.panel.frame.origin,CGPoint(x:origin.x-20,y:origin.y-10))
    }
    func testVisibleTimerIsIndependentOfPetAndDoesNotBlockCompletion()throws {
        let f=try fixture();defer{f.close()}
        XCTAssertTrue(f.window.panel.isVisible);XCTAssertFalse(f.window.panel.canBecomeKey);XCTAssertFalse(f.window.panel.canBecomeMain)
        XCTAssertTrue(f.session.canPresentFocusCompletion)
        try click(f.window.primaryButton);f.session.setVisible(false);f.input.time = .seconds(10);f.focus.refreshTime()
        XCTAssertTrue(f.window.panel.isVisible);XCTAssertEqual(f.window.timeLabel.stringValue,"00:50")
        XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(11));XCTAssertEqual(f.focus.scheduler.pendingCount,1)
        XCTAssertTrue(f.session.focusQuiet)
    }
    func testClosingHidesOnlyWindowAndReopeningDoesNotRestartPhase()throws {
        let f=try fixture();defer{f.close()};try click(f.window.primaryButton)
        f.input.time = .seconds(10);f.window.panel.performClose(nil)
        XCTAssertFalse(f.window.panel.isVisible);XCTAssertEqual(f.focus.status,.running);XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(60))
        XCTAssertFalse(f.session.preferences.focusWindow.isVisible)
        f.input.time = .seconds(25);f.window.setVisible(true)
        XCTAssertEqual(f.window.timeLabel.stringValue,"00:35");XCTAssertEqual(f.focus.status,.running)
        XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(26))
    }
    func testCompletionRemainsVisibleAndStaleButtonCannotStartRest()throws {
        let f=try fixture();defer{f.close()};try click(f.window.primaryButton)
        let oldPause=f.window.primaryButton;f.input.time = .seconds(60);f.focus.refreshTime();try click(oldPause)
        XCTAssertTrue(f.window.panel.isVisible);XCTAssertEqual(f.window.timeLabel.stringValue,"00:00")
        XCTAssertEqual(f.focus.status,.completed);XCTAssertEqual(f.focus.phase,.focus);XCTAssertEqual(f.focus.scheduler.pendingCount,0)
        try click(f.window.primaryButton);XCTAssertEqual(f.focus.phase,.rest);XCTAssertEqual(f.focus.status,.running)
        XCTAssertFalse(f.session.focusQuiet)
    }
    func testDragSavesOnlyAtEndAndPetPlacementStaysIndependent()throws {
        let f=try fixture();defer{f.close()};let pet=f.session.panel.frame,initial=f.input.writes
        for x in [100,120,140]{f.window.panel.setFrameOrigin(CGPoint(x:x,y:200))}
        XCTAssertEqual(f.input.writes,initial)
        f.window.finishDrag();XCTAssertEqual(f.input.writes,initial+1)
        XCTAssertEqual(f.session.preferences.focusWindow.placement?.origin,CGPoint(x:140,y:200));XCTAssertEqual(f.session.panel.frame,pet)
        let another=FocusWindowController(session:f.session,focus:f.focus,canDispatch:{true});defer{another.dispose()};f.window.dispose();another.start()
        XCTAssertEqual(another.panel.frame.origin,CGPoint(x:140,y:200))
    }
    func testRecallShowsTimerAndNeverRecallsHiddenPet()throws {
        let f=try fixture();defer{f.close()};f.session.setVisible(false);let pet=f.session.panel.frame
        f.window.setVisible(false);f.window.recall()
        XCTAssertTrue(f.window.panel.isVisible);XCTAssertFalse(f.session.isVisible);XCTAssertEqual(f.session.panel.frame,pet)
        XCTAssertTrue(f.input.screens[0].visibleFrame.contains(f.window.panel.frame))
    }
    func testPinningAndVisibilitySurviveOtherPreferenceChanges()throws {
        let f=try fixture();defer{f.close()};f.window.setAlwaysOnTop(false)
        XCTAssertEqual(f.window.panel.level,.normal);f.window.setVisible(false)
        var preferences=f.session.preferences;preferences.scale=1.5;f.session.setPreferences(preferences);f.window.refreshPreferences()
        XCTAssertFalse(f.window.panel.isVisible);XCTAssertFalse(f.session.preferences.focusWindow.alwaysOnTop)
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("window must save")}
        XCTAssertFalse(saved.preferences.focusWindow.isVisible);XCTAssertFalse(saved.preferences.focusWindow.alwaysOnTop)
        var bypass=f.session.preferences;bypass.focusWindow.isVisible=true;f.session.setPreferences(bypass)
        XCTAssertFalse(f.session.preferences.focusWindow.isVisible)
    }
    func testFailedSaveKeepsDiskButTemporaryWindowControlWorksAndCanRetry()throws {
        let f=try fixture();defer{f.close()};let bytes=try Data(contentsOf:f.session.settings.url)
        f.input.failWrites=true;f.window.setVisible(false)
        XCTAssertFalse(f.window.panel.isVisible);XCTAssertNotNil(f.window.lastSaveError)
        XCTAssertEqual(try Data(contentsOf:f.session.settings.url),bytes);XCTAssertTrue(f.session.preferences.focusWindow.isVisible)
        f.window.refreshPreferences();XCTAssertFalse(f.window.panel.isVisible)
        f.input.failWrites=false;f.window.retrySave();XCTAssertNil(f.window.lastSaveError);XCTAssertFalse(f.session.preferences.focusWindow.isVisible)
    }
    func testRemovedDisplayClampsTimerWithoutMovingPet()throws {
        let f=try fixture();defer{f.close()}
        f.input.screens.append(.init(id:"left",visibleFrame:CGRect(x:-1400,y:0,width:1400,height:900),isPrimary:false))
        f.window.panel.setFrameOrigin(CGPoint(x:-500,y:200));f.window.finishDrag();let pet=f.session.panel.frame
        f.input.screens.removeLast();f.window.screenChanged()
        XCTAssertTrue(f.input.screens[0].visibleFrame.contains(f.window.panel.frame));XCTAssertEqual(f.session.panel.frame,pet)
    }
    func testModalAndTerminationBlockCommandsAndCancelRestoresDisplay()throws {
        let f=try fixture();defer{f.close()};try click(f.window.primaryButton)
        f.input.blocked=true;try click(f.window.primaryButton);XCTAssertEqual(f.focus.status,.running)
        f.input.blocked=false;f.window.beginTermination();XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(60))
        f.input.time = .seconds(10);f.window.cancelTermination();XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(11))
        XCTAssertEqual(f.window.timeLabel.stringValue,"00:50")
    }
    func testWindowObservationPreservesExistingMenusAndDisposalReleasesDisplay()throws {
        let f=try fixture();defer{f.close()}
        let menus=FocusMenus(focus:f.focus,canDispatch:{true},onSettings:{});defer{menus.dispose()}
        try click(f.window.primaryButton);f.input.time = .seconds(10);f.focus.refreshTime()
        XCTAssertTrue(menus.menus[0].items[0].title.contains("00:50"));XCTAssertEqual(f.window.timeLabel.stringValue,"00:50")
        f.window.dispose();XCTAssertEqual(f.focus.scheduler.scheduledDeadline,.seconds(60))
    }
    func testNativeMenusCanShowRecallAndPinWindowWithoutOpeningSettings()throws {
        let f=try fixture();defer{f.close()}
        let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()}
        status.startShortcuts()
        let menu=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        let show=try XCTUnwrap(menu.items.first{$0.title=="显示桌面计时器"})
        let recall=try XCTUnwrap(menu.items.first{$0.title=="召回计时器"})
        let window=try XCTUnwrap(status.focusWindow)
        XCTAssertTrue(window.panel.isVisible);XCTAssertEqual(show.state,.on)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(show.action),to:show.target,from:show));XCTAssertFalse(window.panel.isVisible)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(recall.action),to:recall.target,from:recall));XCTAssertTrue(window.panel.isVisible)
        XCTAssertNil(status.settingsController)
    }
    func testStartupReadsSavedHiddenWindowBeforeShowingAnything()throws {
        let f=try fixture();defer{f.close()};f.window.setVisible(false)
        let next=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{f.input.screens})
        let status=StatusBarController(session:next,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose();next.prepareToExit()}
        XCTAssertFalse(try XCTUnwrap(status.focusWindow).panel.isVisible)
        next.start();status.startShortcuts();XCTAssertFalse(try XCTUnwrap(status.focusWindow).panel.isVisible)
    }
    func testHeaderMouseSequenceMovesWindowAndSavesOnlyAtMouseUp()throws {
        let f=try fixture();defer{f.close()};let original=f.window.panel.frame.origin,writes=f.input.writes
        let header=try XCTUnwrap(f.window.panel.contentView?.hitTest(CGPoint(x:140,y:190)))
        func event(_ type:NSEvent.EventType,_ point:CGPoint)throws->NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:f.window.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0))
        }
        header.mouseDown(with:try event(.leftMouseDown,CGPoint(x:140,y:190)))
        XCTAssertEqual(f.input.writes,writes,"mouse-down must not save the pre-drag position")
        header.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:110,y:170)))
        XCTAssertEqual(f.window.panel.frame.origin,CGPoint(x:original.x-30,y:original.y-20));XCTAssertEqual(f.input.writes,writes)
        header.mouseUp(with:try event(.leftMouseUp,CGPoint(x:140,y:190)))
        XCTAssertEqual(f.input.writes,writes+1);XCTAssertEqual(f.session.preferences.focusWindow.placement?.origin,CGPoint(x:original.x-30,y:original.y-20))
    }
    func testCompletedButtonsRecoverAfterNativeSettingsSheetEnds()async throws {
        let f=try fixture();defer{f.close()};f.window.dispose()
        let status=StatusBarController(session:f.session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose()};status.startShortcuts()
        let menu=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        menu.performActionForItem(at:try XCTUnwrap(menu.items.firstIndex{$0.title=="专注设置…"}))
        let parent=try XCTUnwrap(status.settingsController?.window),timer=try XCTUnwrap(status.focus),window=try XCTUnwrap(status.focusWindow)
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        parent.beginSheet(sheet,completionHandler:{_ in});timer.startOrResume();f.input.time = .seconds(60);timer.refreshTime()
        XCTAssertEqual(timer.status,.completed);XCTAssertFalse(window.primaryButton.isEnabled)
        parent.endSheet(sheet);sheet.orderOut(nil)
        let limit=ContinuousClock.now + .seconds(1)
        while !window.primaryButton.isEnabled && ContinuousClock.now<limit {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(window.primaryButton.isEnabled,"completed timer must recover after the modal ends")
        window.primaryButton.performClick(nil);XCTAssertEqual(timer.status,.running);XCTAssertEqual(timer.phase,.rest)
    }
    func testHeaderTapDoesNotWritePlacement()throws {
        let f=try fixture();defer{f.close()};let writes=f.input.writes
        let header=try XCTUnwrap(f.window.panel.contentView?.hitTest(CGPoint(x:140,y:190)))
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            header.mouseDownOrUpForTest(type,panel:f.window.panel)
        }
        XCTAssertEqual(f.input.writes,writes)
    }
    func testTerminationCancelsPendingHeaderGesture()throws {
        let f=try fixture();defer{f.close()};let writes=f.input.writes,origin=f.window.panel.frame.origin
        let header=try XCTUnwrap(f.window.panel.contentView?.hitTest(CGPoint(x:140,y:190)))
        header.mouseDownOrUpForTest(.leftMouseDown,panel:f.window.panel);f.window.beginTermination();f.window.cancelTermination()
        let event=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDragged,location:CGPoint(x:110,y:170),modifierFlags:[],timestamp:0,windowNumber:f.window.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0))
        header.mouseDragged(with:event);header.mouseDownOrUpForTest(.leftMouseUp,panel:f.window.panel)
        XCTAssertEqual(f.window.panel.frame.origin,origin);XCTAssertEqual(f.input.writes,writes)
    }
}

@MainActor private extension NSView {
    func mouseDownOrUpForTest(_ type:NSEvent.EventType,panel:NSPanel) {
        guard let event=NSEvent.mouseEvent(with:type,location:CGPoint(x:140,y:190),modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0) else{return XCTFail("Missing event")}
        if type == .leftMouseDown{mouseDown(with:event)}else{mouseUp(with:event)}
    }
}
