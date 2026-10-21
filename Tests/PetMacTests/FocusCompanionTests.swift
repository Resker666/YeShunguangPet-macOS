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
}
