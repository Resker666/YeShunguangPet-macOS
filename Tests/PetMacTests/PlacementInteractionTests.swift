import AppKit
import XCTest
import PetCore

@MainActor private final class PlacementInput {
    var time=Duration.zero,writes=0,reads=0,screenReads=0,failWrites=false
    var screens=[ScreenArea(id:"left",visibleFrame:CGRect(x:-1000,y:40,width:1000,height:700),isPrimary:false),ScreenArea(id:"main",visibleFrame:CGRect(x:0,y:40,width:1000,height:700),isPrimary:true)]
}
@MainActor final class PlacementInteractionTests:XCTestCase {
    @MainActor private struct Fixture {
        let directory:URL,session:PetSession,input:PlacementInput
        func close(){session.prepareToExit();try? FileManager.default.removeItem(at:directory)}
    }
    private func fixture(snap:Bool=false,locked:Bool=false,roaming:Bool=false)throws->Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),input=PlacementInput()
        let manifest=try SkinFixtures.writePackage(in:directory)
        try SkinFixtures.manifest(["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["durationsMs":[1000],"loop":false],"jumping":["durationsMs":[1000],"loop":false],"runningLeft":["durationsMs":[100],"loop":true],"runningRight":["durationsMs":[100],"loop":true]]]).write(to:manifest)
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{data,url in
            if input.failWrites{throw SkinError("disk")};try data.write(to:url,options:.atomic);input.writes+=1
        })
        try store.save(.init(placement:nil,preferences:.init(lookAtMouse:false,desktopRoaming:roaming,roamIntervalSeconds:20,snapToEdges:snap,positionLocked:locked)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{input.screenReads+=1;return input.screens},pointerPosition:{input.reads+=1;return CGPoint(x:2000,y:1000)},roamingRandom:{0.5})
        session.start();session.panel.setFrameOrigin(CGPoint(x:-500,y:300))
        return .init(directory:directory,session:session,input:input)
    }
    private func drag(_ f:Fixture,to point:CGPoint,release:Bool=true) {
        let origin=f.session.panel.frame.origin
        f.session.view.onDown?(.zero,1);f.session.view.onMove?(CGPoint(x:point.x-origin.x,y:point.y-origin.y))
        if release{f.session.view.onUp?(point)}
    }
    func testNormalReleaseSnapsAllVisibleCornersAtTwelveLogicalPointsAndSavesOnce()throws {
        let f=try fixture(snap:true);defer{f.close()}
        for (near,corner) in [(CGPoint(x:-988,y:52),CGPoint(x:-1000,y:40)),(CGPoint(x:-44,y:52),CGPoint(x:-32,y:40)),(CGPoint(x:-988,y:696),CGPoint(x:-1000,y:708)),(CGPoint(x:-44,y:696),CGPoint(x:-32,y:708))] {
            f.session.panel.setFrameOrigin(CGPoint(x:-500,y:300));let before=f.input.writes
            drag(f,to:near,release:false);XCTAssertEqual(f.session.panel.frame.origin,near);XCTAssertEqual(f.input.writes,before)
            f.session.view.onUp?(near);XCTAssertEqual(f.session.panel.frame.origin,corner);XCTAssertEqual(f.input.writes,before+1)
            guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("saved position")}
            XCTAssertEqual(saved.placement?.origin,corner)
        }
        XCTAssertEqual(f.session.scheduler.pendingCount,1)
    }
    func testSnapDisabledOrBeyondThresholdAndMostIntersectingScreen()throws {
        let f=try fixture();defer{f.close()}
        drag(f,to:CGPoint(x:-988,y:52));XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:-988,y:52))
        var prefs=f.session.preferences;prefs.snapToEdges=true;f.session.setPreferences(prefs)
        f.session.panel.setFrameOrigin(CGPoint(x:-500,y:300))
        drag(f,to:CGPoint(x:-987,y:53));XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:-987,y:53))
        drag(f,to:CGPoint(x:-10,y:200));XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:0,y:200))
        f.input.screens=[.init(id:"tiny",visibleFrame:CGRect(x:-100,y:-100,width:20,height:20),isPrimary:true)]
        drag(f,to:CGPoint(x:-90,y:-90));XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:-100,y:-100))
    }
    func testInterruptedDragAndRecallDoNotSnap()throws {
        let f=try fixture(snap:true);defer{f.close()}
        for interrupt in ["menu","lock","settings","sleep","hide"] {
            f.session.panel.setFrameOrigin(CGPoint(x:-500,y:300));drag(f,to:CGPoint(x:-988,y:52),release:false)
            switch interrupt {
            case "menu":f.session.setMenuOpen(true)
            case "lock":var prefs=f.session.preferences;prefs.positionLocked=true;f.session.setPreferences(prefs)
            case "settings":f.session.setSettingsOpen(true)
            case "sleep":f.session.setSleeping(true)
            default:f.session.setVisible(false)
            }
            XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:-988,y:52),interrupt);XCTAssertFalse(f.session.interaction.isPointerBusy)
            f.session.view.onUp?(.zero);XCTAssertNil(f.session.interaction.nextClickDeadline)
            f.session.setMenuOpen(false);f.session.setSettingsOpen(false);f.session.setSleeping(false);f.session.setVisible(true)
            var prefs=f.session.preferences;prefs.positionLocked=false;f.session.setPreferences(prefs)
        }
        f.session.recall();XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:944,y:64))
    }
    func testLockedDraggingCannotMoveWriteOrTurnIntoClickButSingleDoubleClickRemain()throws {
        let f=try fixture(snap:true,locked:true);defer{f.close()}
        let original=f.session.panel.frame.origin,before=f.input.writes
        for count in [1,2] {
            f.session.view.onDown?(.zero,count);f.session.view.onMove?(CGPoint(x:20,y:30));f.session.view.onUp?(CGPoint(x:20,y:30))
            XCTAssertEqual(f.session.panel.frame.origin,original);XCTAssertEqual(f.input.writes,before);XCTAssertNil(f.session.interaction.nextClickDeadline)
        }
        f.session.view.onDown?(.zero,1);f.session.view.onUp?(.zero)
        f.input.time=try XCTUnwrap(f.session.interaction.nextClickDeadline);f.session.tick();XCTAssertEqual(f.session.action,.waving)
        f.session.view.onDown?(.zero,2);f.session.view.onUp?(.zero);XCTAssertEqual(f.session.action,.jumping)
        XCTAssertTrue(f.session.preferences.positionLocked)
    }
    func testLockStopsRoamingWithoutPointerPollingAndUnlockStartsFreshWait()throws {
        let f=try fixture(locked:true,roaming:true);defer{f.close()}
        let original=f.session.panel.frame.origin,screenReads=f.input.screenReads
        f.input.time = .seconds(1000);f.session.tick()
        XCTAssertEqual(f.session.panel.frame.origin,original);XCTAssertEqual(f.input.reads,0);XCTAssertEqual(f.input.screenReads,screenReads)
        var prefs=f.session.preferences;prefs.positionLocked=false;f.session.setPreferences(prefs)
        f.session.tick();XCTAssertEqual(f.input.reads,0)
        f.input.time += .seconds(20);f.session.tick();XCTAssertEqual(f.session.action,.runningRight)
        f.input.time += .milliseconds(100);f.session.tick();XCTAssertGreaterThan(f.session.panel.frame.minX,original.x)
        prefs.positionLocked=true;f.session.setPreferences(prefs)
        let stopped=f.session.panel.frame.origin,reads=f.input.reads,writes=f.input.writes
        f.input.time += .seconds(1000);f.session.tick();XCTAssertEqual(f.session.panel.frame.origin,stopped);XCTAssertEqual(f.input.reads,reads);XCTAssertEqual(f.input.writes,writes)
        XCTAssertTrue(f.session.preferences.desktopRoaming);XCTAssertTrue(f.session.preferences.positionLocked)
    }
    func testLockedRecallHiddenScreenCorrectionAndReopenRetainPreferences()throws {
        let f=try fixture(snap:true,locked:true);defer{f.close()}
        f.session.setVisible(false);f.session.recall();XCTAssertTrue(f.session.isVisible);XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:944,y:64))
        f.session.setVisible(false);f.input.screens=[.init(id:"replacement",visibleFrame:CGRect(x:-300,y:-200,width:300,height:200),isPrimary:true)];f.session.screensChanged()
        XCTAssertFalse(f.session.isVisible);XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:-56,y:-176))
        let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{f.input.screens});defer{reopened.prepareToExit()}
        reopened.start();XCTAssertTrue(reopened.preferences.positionLocked);XCTAssertTrue(reopened.preferences.snapToEdges);XCTAssertEqual(reopened.panel.frame.origin,f.session.panel.frame.origin)
    }
    func testGeneralSettingsTogglesPersistAndExposeSaveFailure()throws {
        let f=try fixture();defer{f.close()}
        let model=SettingsModel(session:f.session)
        XCTAssertFalse(model.preferences.snapToEdges);XCTAssertFalse(model.preferences.positionLocked)
        model.setSnapToEdges(true);model.setPositionLocked(true)
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("saved")}
        XCTAssertTrue(saved.preferences.snapToEdges);XCTAssertTrue(saved.preferences.positionLocked)
        f.input.failWrites=true;model.setSnapToEdges(false);XCTAssertNotNil(model.saveError);XCTAssertFalse(model.preferences.snapToEdges)
        f.input.failWrites=false;f.session.retrySave();model.refresh();XCTAssertNil(model.saveError)
        model.beginTermination();model.setPositionLocked(false);XCTAssertTrue(f.session.preferences.positionLocked)
    }
}
