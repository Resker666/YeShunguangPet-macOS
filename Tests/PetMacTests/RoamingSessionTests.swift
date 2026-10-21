import AppKit
import XCTest
import PetCore

@MainActor private final class RoamingInput {
    var time=Duration.zero,point=CGPoint(x:900,y:650),reads=0,screenReads=0,writes=0,failWrites=false
    var screens=[ScreenArea(id:"left",visibleFrame:CGRect(x:-200,y:-100,width:1000,height:700),isPrimary:true)]
}
@MainActor final class RoamingSessionTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory:URL,session:PetSession,input:RoamingInput
        func close() { session.prepareToExit();try? FileManager.default.removeItem(at:directory) }
    }
    private func fixture(enabled:Bool=true,support:Bool=true,automatic:Bool=false,gaze:Bool=false,automaticDraw:Double=0) throws -> Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),input=RoamingInput()
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("default"))
        var animations:[String:Any]=["idle":["durationsMs":[300,200],"loop":true],"jumping":["durationsMs":[5000],"loop":false],"waving":["durationsMs":[1000],"loop":false]]
        if support { for name in ["runningRight","runningLeft"] { animations[name]=["startColumn":1,"durationsMs":[100],"loop":true] } }
        try SkinFixtures.manifest(["animations":animations,"lookDirections":(0..<16).map{_ in ["row":0,"column":0]}]).write(to:manifest)
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{ data,url in
            if input.failWrites { throw SkinError("write failed") };try data.write(to:url,options:.atomic);input.writes += 1
        })
        try store.save(.init(placement:nil,preferences:.init(lookAtMouse:gaze,automaticActions:automatic,automaticActionIntervalSeconds:20,desktopRoaming:enabled,roamIntervalSeconds:20)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{input.screenReads += 1;return input.screens},pointerPosition:{input.reads += 1;return input.point},automaticRandom:{automaticDraw},roamingRandom:{0.5})
        session.start();session.panel.setFrameOrigin(CGPoint(x:100,y:100))
        return .init(directory:directory,session:session,input:input)
    }
    private func advance(_ f:Fixture,from start:Int=20000) {
        for i in 1...23 { f.input.time = .milliseconds(start+i*100);f.session.tick() }
    }
    private func metrics(_ f:Fixture) throws -> [String:Any] {
        let url=f.directory.appendingPathComponent("metrics.json");try f.session.exportMetrics(to:url)
        return try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    }
    func testWalkUsesDirectionCropAndSavesOnlyAtCompletionThenRestores() throws {
        let f=try fixture();defer{f.close()};let before=f.input.writes
        f.input.time = .seconds(20);f.session.tick();XCTAssertEqual(f.session.action,.runningRight)
        XCTAssertEqual(f.session.scheduler.pendingCount,1);XCTAssertEqual(f.input.writes,before)
        let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(f.session.view.image));var pixel=[Int](repeating:0,count:4);bitmap.getPixel(&pixel,atX:1,y:1);XCTAssertEqual(pixel[0],128)
        advance(f)
        XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:190,y:100));XCTAssertEqual(f.session.action,.idle)
        XCTAssertEqual(f.input.writes,before+1);XCTAssertEqual(try metrics(f)["roamingCount"] as? Int,1)
        let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{f.input.screens})
        defer{reopened.prepareToExit()};reopened.start();XCTAssertEqual(reopened.panel.frame.origin,CGPoint(x:190,y:100));XCTAssertTrue(reopened.preferences.desktopRoaming)
    }
    func testMouseProximityPausesAndUsesHysteresisBeforeResuming() throws {
        let f=try fixture();defer{f.close()}
        f.input.time = .seconds(20);f.session.tick()
        f.input.point=CGPoint(x:180,y:116);f.input.time = .milliseconds(20100);f.session.tick()
        XCTAssertEqual(f.session.panel.frame.minX,100);XCTAssertEqual(f.session.action,.idle)
        f.input.point=CGPoint(x:222,y:116);f.input.time = .seconds(500);f.session.tick() // 90 points from rectangle, still paused.
        XCTAssertEqual(f.session.panel.frame.minX,100)
        f.input.point=CGPoint(x:900,y:650);f.input.time += .milliseconds(100);f.session.tick()
        XCTAssertEqual(f.session.panel.frame.minX,104,accuracy:0.0001);XCTAssertEqual(f.session.action,.runningRight)
    }
    func testPressDragAndManualActionStopWalkAndPreservePriorities() throws {
        let f=try fixture();defer{f.close()}
        f.input.time = .seconds(20);f.session.tick();f.input.time += .milliseconds(100);f.session.tick()
        f.session.view.onDown?(.zero,1);XCTAssertEqual(f.session.action,.idle)
        f.input.time = .seconds(100);f.session.tick();XCTAssertEqual(f.session.panel.frame.minX,104,accuracy:0.0001)
        f.session.view.onMove?(CGPoint(x:20,y:10));f.session.view.onUp?(CGPoint(x:20,y:10))
        XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:124,y:110))
        f.session.play(.jumping);f.input.time += .seconds(4);f.session.tick();XCTAssertEqual(f.session.action,.jumping)
        XCTAssertEqual(try metrics(f)["roamingCount"] as? Int,1)
    }
    func testMenusSettingsHiddenSleepAndDisplayChangeEndMotionAndSaveCurrentPoint() throws {
        for blocker in ["menu","settings","hidden","sleep","display"] {
            let f=try fixture();defer{f.close()}
            f.input.time = .seconds(20);f.session.tick();f.input.time += .milliseconds(100);f.session.tick()
            switch blocker {
            case "menu":f.session.setMenuOpen(true)
            case "settings":f.session.setSettingsOpen(true)
            case "hidden":f.session.setVisible(false)
            case "sleep":f.session.setSleeping(true)
            default:f.input.screens=[.init(id:"new",visibleFrame:CGRect(x:-1000,y:0,width:800,height:600),isPrimary:true)];f.session.screensChanged()
            }
            let stopped=f.session.panel.frame.origin,reads=f.input.reads
            f.input.time += .seconds(1);f.session.tick();XCTAssertEqual(f.session.panel.frame.origin,stopped,blocker);XCTAssertEqual(f.input.reads,reads,blocker)
            XCTAssertEqual(f.session.action,.idle,blocker)
            if blocker=="hidden" || blocker=="sleep" { XCTAssertEqual(f.session.scheduler.pendingCount,0) }
            guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else { XCTFail("position missing");continue }
            XCTAssertEqual(saved.placement?.origin,stopped)
        }
    }
    func testAutomaticGestureWaitsForRoamingAndGazeDoesNotReplaceWalk() throws {
        let f=try fixture(automatic:true,gaze:true);defer{f.close()}
        // First gesture due at 15 seconds; manually complete it before roaming's remaining wait.
        f.input.time = .seconds(15);f.session.tick();XCTAssertTrue([PetAction.waving,.jumping].contains(f.session.action))
        f.input.time = .seconds(20);f.session.tick();XCTAssertEqual(f.session.action,.idle)
        f.input.time = .seconds(25);f.session.tick();XCTAssertEqual(f.session.action,.runningRight);XCTAssertNil(f.session.gazeDirection)
        advance(f,from:25000);XCTAssertEqual(f.session.action,.idle)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,1);XCTAssertEqual(try metrics(f)["roamingCount"] as? Int,1)
    }
    func testDisabledUnsupportedAndNoSpaceNeverReadPointerForRoaming() throws {
        for (enabled,support) in [(false,true),(true,false)] {
            let f=try fixture(enabled:enabled,support:support);defer{f.close()};let before=f.input.screenReads;f.input.time = .seconds(500);f.session.tick()
            XCTAssertEqual(f.input.reads,0);XCTAssertEqual(f.session.panel.frame.minX,100);XCTAssertEqual(f.session.action,.idle);XCTAssertEqual(f.input.screenReads,before)
        }
        let f=try fixture();defer{f.close()};f.input.screens=[.init(id:"tiny",visibleFrame:CGRect(x:0,y:0,width:40,height:40),isPrimary:true)];f.session.screensChanged()
        f.input.time = .seconds(100);f.session.tick();XCTAssertEqual(f.input.reads,0)
    }
    func testSettingsFailureRetryPreservesSelectionAndDisableOnlyStopsRoaming() throws {
        let f=try fixture();defer{f.close()}
        let imported=try f.session.library.install(SkinLoader.readPackage(manifestURL:f.directory.appendingPathComponent("default/pet.json")));try f.session.useImportedSkin(imported)
        f.input.time = .seconds(20);f.session.tick();f.input.time += .milliseconds(100);f.session.tick()
        let model=SettingsModel(session:f.session);f.input.failWrites=true;model.setDesktopRoaming(false)
        XCTAssertEqual(f.session.action,.idle);XCTAssertNotNil(model.saveError)
        f.input.failWrites=false;f.session.retrySave();model.setRoamInterval(180)
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("missing")}
        XCTAssertFalse(saved.preferences.desktopRoaming);XCTAssertEqual(saved.preferences.roamIntervalSeconds,180);XCTAssertEqual(saved.selectedSkinID,imported.id)
        f.session.play(.jumping);model.setDesktopRoaming(true);XCTAssertEqual(f.session.action,.jumping)
        model.setRoamInterval(19);XCTAssertEqual(f.session.preferences.roamIntervalSeconds,180)
    }
    func testExitCancelsAllMotionScheduling() throws {
        let f=try fixture();defer{f.close()};f.input.time = .seconds(20);f.session.tick()
        f.session.prepareToExit();let point=f.session.panel.frame.origin,reads=f.input.reads
        f.input.time = .seconds(1000);f.session.tick();XCTAssertEqual(f.session.scheduler.pendingCount,0);XCTAssertEqual(f.session.panel.frame.origin,point);XCTAssertEqual(f.input.reads,reads)
    }
    func testNoScreensInterruptionRetainsMovedPointForSaveRetryAndRestart() throws {
        for fail in [false,true] {
            let f=try fixture();defer{f.close()};let originalScreens=f.input.screens
            f.session.finishDrag()
            f.input.time = .seconds(20);f.session.tick();f.input.time += .milliseconds(100);f.session.tick()
            XCTAssertEqual(f.session.panel.frame.minX,104,accuracy:0.0001)
            f.input.failWrites=fail;f.input.screens=[];f.session.screensChanged()
            let reads=f.input.reads
            f.input.time += .seconds(100);f.session.tick()
            XCTAssertEqual(f.session.scheduler.pendingCount,0);XCTAssertEqual(f.input.reads,reads)
            if fail { XCTAssertNotNil(f.session.persistenceError);f.input.failWrites=false;f.session.retrySave() }
            guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("snapshot missing")}
            XCTAssertEqual(saved.placement?.origin,CGPoint(x:104,y:100));XCTAssertEqual(saved.placement?.screenID,"left")
            XCTAssertTrue(f.session.requestExit());f.session.prepareToExit()
            let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{originalScreens})
            defer{reopened.prepareToExit()};reopened.start()
            XCTAssertEqual(reopened.panel.frame.origin,CGPoint(x:104,y:100))
        }
    }
    func testQuitDuringMotionRetainsPositionBeforeNoScreensNotificationArrives() throws {
        let f=try fixture();defer{f.close()};f.session.finishDrag()
        f.input.time = .seconds(20);f.session.tick();f.input.time += .milliseconds(100);f.session.tick()
        f.input.screens=[]
        XCTAssertTrue(f.session.requestExit())
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("quit snapshot missing")}
        XCTAssertEqual(saved.placement?.origin,CGPoint(x:104,y:100))
        XCTAssertEqual(f.session.action,.idle)
    }
    private func toggleQuiet(_ status:StatusBarController) throws {
        let item=try XCTUnwrap(status.menu.items.first{$0.title=="安静模式"})
        status.menu.performActionForItem(at:status.menu.index(of:item))
    }
    func testQuietModeStopsAutomaticSamplingWithoutChangingPreferencesOrManualInteraction() throws {
        let f=try fixture(automatic:true,gaze:true);defer{f.close()}
        let status=StatusBarController(session:f.session,onQuit:{});defer{status.dispose()}
        let before=try Data(contentsOf:f.session.settings.url),preferences=f.session.preferences
        try toggleQuiet(status)
        let reads=f.input.reads,screens=f.input.screenReads
        f.input.time = .seconds(500);f.session.tick()
        XCTAssertEqual(f.input.reads,reads);XCTAssertEqual(f.input.screenReads,screens)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,0)
        XCTAssertEqual(try metrics(f)["roamingCount"] as? Int,0)
        XCTAssertNil(f.session.gazeDirection);XCTAssertEqual(f.session.scheduler.pendingCount,1)
        XCTAssertEqual(f.session.preferences,preferences);XCTAssertEqual(try Data(contentsOf:f.session.settings.url),before)
        f.session.view.onDown?(.zero,1);f.session.view.onUp?(.zero)
        f.input.time += .seconds(1);f.session.tick();XCTAssertEqual(f.session.action,.waving)
        f.session.view.onDown?(.zero,1);f.session.view.onMove?(CGPoint(x:20,y:10));f.session.view.onUp?(CGPoint(x:20,y:10))
        XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:120,y:110));XCTAssertEqual(f.session.action,.idle)
        XCTAssertEqual(f.session.preferences,preferences)
    }
    func testQuietModeInterruptsWalkAndSavesOnceThenResumesWaiting() throws {
        let f=try fixture();defer{f.close()}
        let status=StatusBarController(session:f.session,onQuit:{});defer{status.dispose()}
        f.input.time = .seconds(20);f.session.tick();f.input.time += .milliseconds(100);f.session.tick()
        let writes=f.input.writes
        try toggleQuiet(status)
        XCTAssertEqual(f.session.action,.idle);XCTAssertEqual(f.input.writes,writes+1)
        f.input.time = .seconds(500);f.session.tick();XCTAssertEqual(f.session.panel.frame.minX,104)
        XCTAssertEqual(f.input.writes,writes+1)
        try toggleQuiet(status);f.session.tick()
        XCTAssertEqual(f.session.action,.idle);XCTAssertEqual(try metrics(f)["roamingCount"] as? Int,1)
        XCTAssertTrue(f.session.preferences.desktopRoaming)
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("missing saved point")}
        XCTAssertEqual(saved.placement?.origin,CGPoint(x:104,y:100))
    }
    func testQuietModeEndsAutomaticGestureAndActiveGaze() throws {
        let f=try fixture(automatic:true,gaze:true);defer{f.close()}
        let status=StatusBarController(session:f.session,onQuit:{});defer{status.dispose()}
        f.input.point=CGPoint(x:216,y:116);f.input.time = .milliseconds(100);f.session.tick()
        XCTAssertNotNil(f.session.gazeDirection)
        try toggleQuiet(status);XCTAssertNil(f.session.gazeDirection)
        try toggleQuiet(status)
        f.input.point=CGPoint(x:900,y:650);f.input.time = .seconds(15);f.session.tick()
        XCTAssertEqual(f.session.action,.waving)
        try toggleQuiet(status);XCTAssertEqual(f.session.action,.idle)
        f.input.time = .seconds(500);f.session.tick();try toggleQuiet(status);f.session.tick()
        XCTAssertEqual(f.session.action,.idle);XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,1)
    }
    func testQuietModeIsTemporaryAndReopeningRetainsOriginalAutomationPreferences() throws {
        let f=try fixture(automatic:true,gaze:true);defer{f.close()}
        let status=StatusBarController(session:f.session,onQuit:{});defer{status.dispose()}
        try toggleQuiet(status)
        XCTAssertEqual(status.menu.items.first{$0.title=="安静模式"}?.state,.on)
        XCTAssertTrue(f.session.requestExit())
        let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{f.input.screens})
        defer{reopened.prepareToExit()};reopened.start()
        let other=StatusBarController(session:reopened,onQuit:{});defer{other.dispose()}
        XCTAssertEqual(other.menu.items.first{$0.title=="安静模式"}?.state,.off)
        XCTAssertEqual(reopened.preferences,f.session.preferences)
    }
    func testRoamingWinsWhenAutomaticGestureIsDueAtExactlyTheSameTime() throws {
        let f=try fixture(automatic:true,gaze:true,automaticDraw:0.5);defer{f.close()}
        f.input.time = .seconds(20);f.session.tick()
        XCTAssertEqual(f.session.action,.runningRight);XCTAssertNil(f.session.gazeDirection)
        XCTAssertEqual(try metrics(f)["roamingCount"] as? Int,1)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,0)
        f.input.time += .milliseconds(100);f.session.tick()
        XCTAssertEqual(f.session.action,.runningRight);XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,0)
        XCTAssertEqual(f.session.scheduler.pendingCount,1)
    }
}
