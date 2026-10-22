import AppKit
import XCTest
import PetCore

@MainActor private final class StatisticsInput {
    var time=Duration.zero,date=Date(timeIntervalSince1970:1792670400)
    var zone=TimeZone(secondsFromGMT:0)!,failWrites=false,modal=false
    var writes=0
}
@MainActor final class FocusPresetStatisticsTests:XCTestCase {
    @MainActor private struct Fixture {
        let directory:URL,session:PetSession,focus:FocusController,input:StatisticsInput
        func close(){focus.dispose();session.prepareToExit();try? FileManager.default.removeItem(at:directory)}
        func saved()throws->PetSettings {
            guard case .loaded(let saved)=SettingsStore(url:session.settings.url).load() else{throw SkinError("Expected valid settings")};return saved
        }
    }
    private func fixture(protected:Bool=false)throws->Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),input=StatisticsInput()
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("skin"))
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{data,url in
            if input.failWrites{throw SkinError("injected statistics write failure")};input.writes+=1;try data.write(to:url,options:.atomic)
        })
        try store.save(.init(placement:nil,preferences:.init(lookAtMouse:false,focusMinutes:1,breakMinutes:1)))
        if protected{try Data("{broken".utf8).write(to:store.url)}
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{[.init(id:"test",visibleFrame:CGRect(x:0,y:0,width:1200,height:900),isPrimary:true)]})
        session.start()
        let focus=FocusController(session:session,playCompletionSound:{},wallNow:{input.date},timeZone:{input.zone})
        focus.canPlayCompletionSound = {!input.modal}
        return .init(directory:directory,session:session,focus:focus,input:input)
    }
    func testEveryPresetCommitsDurationBeforeStartingAndKeepsBreakDuration()throws {
        for (minutes,seconds) in [(15,900),(25,1500),(45,2700),(60,3600)] {
            let f=try fixture();defer{f.close()}
            f.focus.startPreset(f.focus.presetCommand(minutes:minutes))
            XCTAssertEqual(f.focus.status,.running);XCTAssertEqual(f.focus.remainingSeconds,seconds)
            let saved=try f.saved();XCTAssertEqual(saved.preferences.focusMinutes,minutes);XCTAssertEqual(saved.preferences.breakMinutes,1)
            XCTAssertEqual(f.focus.todayStatistics.completedCount,0)
        }
    }
    func testFailedPresetSaveLeavesReadyTimerAndOriginalDiskThenRetryCanStart()throws {
        let f=try fixture();defer{f.close()};let bytes=try Data(contentsOf:f.session.settings.url)
        f.input.failWrites=true;f.focus.startPreset(f.focus.presetCommand(minutes:45))
        XCTAssertEqual(f.focus.status,.ready);XCTAssertEqual(f.focus.remainingSeconds,60);XCTAssertEqual(f.focus.focusMinutes,1)
        XCTAssertNotNil(f.focus.presetError);XCTAssertEqual(try Data(contentsOf:f.session.settings.url),bytes)
        f.input.failWrites=false;f.focus.startPreset(f.focus.presetCommand(minutes:45));XCTAssertEqual(f.focus.remainingSeconds,2700);XCTAssertNil(f.focus.presetError)
    }
    func testStalePresetCannotChangeRunningPausedCompletedOrResetGeneration()throws {
        let f=try fixture();defer{f.close()};let old=f.focus.presetCommand(minutes:15)
        f.focus.startOrResume();f.focus.startPreset(old);XCTAssertEqual(f.focus.remainingSeconds,60)
        f.focus.pause();f.focus.startPreset(old);XCTAssertEqual(f.focus.status,.paused)
        f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime();f.focus.startPreset(old);XCTAssertEqual(f.focus.status,.completed)
        f.focus.reset();f.focus.startPreset(old);XCTAssertEqual(f.focus.status,.ready);XCTAssertEqual(f.focus.focusMinutes,1)
    }
    func testModalSleepExitAndInvalidPresetCannotStart()throws {
        let f=try fixture();defer{f.close()};let command=f.focus.presetCommand(minutes:25),writes=f.input.writes
        f.input.modal=true;f.focus.startPreset(command);f.input.modal=false
        f.focus.setSleeping(true);f.focus.startPreset(command);f.focus.setSleeping(false)
        f.focus.setTerminating(true);f.focus.startPreset(command);f.focus.setTerminating(false)
        f.focus.startPreset(f.focus.presetCommand(minutes:37))
        XCTAssertEqual(f.focus.status,.ready);XCTAssertEqual(f.input.writes,writes)
    }
    func testOnlyFocusCompletionCountsOnceAndRestAndResetDoNotAddOrErase()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime()
        let writes=f.input.writes;for _ in 0..<4{f.focus.refreshTime();f.focus.setSleeping(false)}
        XCTAssertEqual(f.input.writes,writes);XCTAssertEqual(f.focus.todayStatistics.completedCount,1);XCTAssertEqual(f.focus.todayStatistics.plannedMinutes,1)
        f.focus.startOrResume();f.input.time = .seconds(120);f.focus.refreshTime();f.focus.reset()
        XCTAssertEqual(f.focus.todayStatistics.completedCount,1);XCTAssertEqual(try f.saved().focusStatistics.plannedMinutes,1)
    }
    func testPausedTimeAndAbandonedFocusDoNotAccumulatePartialMinutes()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(10);f.focus.pause()
        f.input.time = .seconds(80);f.focus.refreshTime();XCTAssertEqual(f.focus.todayStatistics.completedCount,0)
        f.focus.startOrResume();f.input.time = .seconds(130);f.focus.refreshTime();XCTAssertEqual(f.focus.todayStatistics.plannedMinutes,1)
        f.focus.reset();f.focus.startOrResume();f.input.time = .seconds(150);f.focus.reset()
        f.focus.startOrResume();f.input.time = .seconds(170);f.focus.dispose();XCTAssertTrue(f.session.requestExit())
        XCTAssertEqual(try f.saved().focusStatistics.completedCount,1)
    }
    func testSleepCompletionBelongsToWakeSettlementDayAndCannotReplay()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.focus.setSleeping(true)
        f.input.time = .seconds(100);f.input.date+=86400;f.focus.setSleeping(false);f.focus.setSleeping(false)
        XCTAssertEqual(f.focus.todayStatistics.day,"2026-10-23");XCTAssertEqual(f.focus.todayStatistics.plannedMinutes,1)
        XCTAssertEqual(try f.saved().focusStatistics.completedCount,1)
    }
    func testDayNotificationRefreshesIdleMenusWithoutTimerOrWritingEveryTick()throws {
        let f=try fixture();defer{f.close()};let menus=FocusMenus(focus:f.focus,canDispatch:{true},onSettings:{});defer{menus.dispose()}
        f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime();let writes=f.input.writes
        f.input.date+=86400;NotificationCenter.default.post(name:.NSCalendarDayChanged,object:nil)
        XCTAssertEqual(f.focus.todayStatistics.completedCount,0);XCTAssertEqual(f.focus.todayStatistics.day,"2026-10-23")
        XCTAssertEqual(f.focus.scheduler.pendingCount,0);XCTAssertEqual(f.input.writes,writes)
        XCTAssertTrue(menus.menus.allSatisfy{$0.items.contains{$0.title.contains("今日") && $0.title.contains("0 次")}})
    }
    func testTimeZoneChangeRefreshesCurrentDayWithoutReattributingSavedDay()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime()
        f.input.zone=TimeZone(secondsFromGMT:14*3600)!;NotificationCenter.default.post(name:.NSSystemTimeZoneDidChange,object:nil)
        XCTAssertEqual(f.focus.todayStatistics.day,"2026-10-23");XCTAssertEqual(f.focus.todayStatistics.completedCount,0)
        XCTAssertEqual(try f.saved().focusStatistics.day,"2026-10-22")
    }
    func testFailedStatisticsWriteRetainsPendingAggregateAndRetriesWithoutDuplicating()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();let bytes=try Data(contentsOf:f.session.settings.url)
        f.input.failWrites=true;f.input.time = .seconds(60);f.focus.refreshTime();f.focus.refreshTime()
        XCTAssertEqual(f.focus.todayStatistics.completedCount,1);XCTAssertNotNil(f.focus.statisticsSaveError);XCTAssertEqual(try Data(contentsOf:f.session.settings.url),bytes)
        f.focus.reset();f.focus.startOrResume();f.input.time = .seconds(120);f.focus.refreshTime()
        XCTAssertEqual(f.focus.todayStatistics.completedCount,2)
        f.input.failWrites=false;f.focus.retryStatisticsSaving();f.focus.retryStatisticsSaving()
        XCTAssertEqual(try f.saved().focusStatistics.completedCount,2);XCTAssertNil(f.focus.statisticsSaveError)
    }
    func testEveryExistingSettingsWriteCarriesPendingStatisticsAndExitCanRetry()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.failWrites=true;f.input.time = .seconds(60);f.focus.refreshTime()
        XCTAssertFalse(f.session.requestExit());f.input.failWrites=false
        var p=f.session.preferences;p.scale=1.5;f.session.setPreferences(p)
        try f.session.saveKeyboardShortcuts([]);try f.session.saveFocusWindow(.init(compact:true));try f.session.restoreDefaultSkin()
        f.focus.refreshConfiguration();XCTAssertNil(f.focus.statisticsSaveError);XCTAssertTrue(f.session.requestExit())
        XCTAssertEqual(try f.saved().focusStatistics.completedCount,1)
    }
    func testProtectedFileRetainsBytesUntilExplicitIsolatedRecovery()throws {
        let f=try fixture(protected:true);defer{f.close()};let bytes=try Data(contentsOf:f.session.settings.url)
        f.focus.startOrResume();f.input.time = .seconds(1500);f.focus.refreshTime()
        XCTAssertEqual(f.focus.todayStatistics.plannedMinutes,25);XCTAssertNotNil(f.focus.statisticsSaveError)
        f.focus.retryStatisticsSaving();XCTAssertEqual(try Data(contentsOf:f.session.settings.url),bytes)
        f.session.resetProtectedSettings();f.focus.refreshConfiguration()
        XCTAssertEqual(try f.saved().focusStatistics.plannedMinutes,25);XCTAssertNil(f.focus.statisticsSaveError)
    }
    func testPersistedAggregateRestoresInNewControllerWithoutRestoringRun()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime()
        let session=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:f.session.screens);session.start();defer{session.prepareToExit()}
        let next=FocusController(session:session,playCompletionSound:{},wallNow:{f.input.date},timeZone:{f.input.zone});defer{next.dispose()}
        XCTAssertEqual(next.status,.ready);XCTAssertEqual(next.todayStatistics.completedCount,1)
    }
    func testNativePresetMenuDisablesAfterStartingAndOldItemCannotRestart()throws {
        let f=try fixture();defer{f.close()};let menus=FocusMenus(focus:f.focus,canDispatch:{true},onSettings:{});defer{menus.dispose()}
        let submenu=try XCTUnwrap(menus.menus[0].items.first{$0.title=="快捷开始"}?.submenu)
        let first=try XCTUnwrap(submenu.items.first);submenu.performActionForItem(at:0)
        XCTAssertEqual(f.focus.remainingSeconds,900);XCTAssertTrue(submenu.items.allSatisfy{!$0.isEnabled})
        f.focus.reset();XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(first.action),to:first.target,from:first));XCTAssertEqual(f.focus.status,.ready)
    }
    func testStatusOwnerLoadsStatisticsAfterSessionStartAndTracksPresetSubmenus()throws {
        let f=try fixture();defer{f.close()};f.focus.startOrResume();f.input.time = .seconds(60);f.focus.refreshTime()
        let session=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:f.session.screens)
        let status=StatusBarController(session:session,registry:FakeHotKeyRegistry(),onQuit:{});defer{status.dispose();session.prepareToExit()}
        session.start();status.startShortcuts()
        let focus=try XCTUnwrap(status.focus)
        // The owner uses the actual local day; compare persisted data via the session.
        XCTAssertEqual(session.focusStatistics.completedCount,1)
        let root=try XCTUnwrap(status.menu.items.first{$0.title=="专注计时"}?.submenu)
        let presets=try XCTUnwrap(root.items.first{$0.title=="快捷开始"}?.submenu)
        XCTAssertTrue(presets.delegate === status)
        status.menuWillOpen(root);status.menuWillOpen(presets);status.menuDidClose(root)
        XCTAssertFalse(session.canPresentFocusCompletion,"an open preset submenu must retain menu suppression")
        status.menuDidClose(presets);XCTAssertTrue(session.canPresentFocusCompletion)
        XCTAssertEqual(focus.status,.ready)
    }
}
