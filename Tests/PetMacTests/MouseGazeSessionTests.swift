import AppKit
import XCTest
import PetCore

@MainActor private final class GazeInput {
    var time=Duration.zero, point=CGPoint(x:216,y:116), reads=0, failWrites=false
}
@MainActor final class MouseGazeSessionTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL,session: PetSession,input: GazeInput
        func close() { session.prepareToExit(); try? FileManager.default.removeItem(at:directory) }
    }
    private func fixture(enabled: Bool = true,support: Bool = true) throws -> Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("default"))
        var fields:[String:Any]=["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["durationsMs":[100],"loop":false],"jumping":["durationsMs":[100],"loop":false]]]
        if support { fields["lookDirections"]=(0..<16).map{["row":0,"column":$0==4 ? 1 : 0]} }
        try SkinFixtures.manifest(fields).write(to:manifest)
        let input=GazeInput()
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{ data,url in
            if input.failWrites { throw SkinError("写入失败") }; try data.write(to:url,options:.atomic)
        })
        try store.save(PetSettings(placement:nil,preferences:.init(lookAtMouse:enabled)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]},pointerPosition:{input.reads += 1; return input.point})
        session.start(); session.panel.setFrameOrigin(CGPoint(x:100,y:100))
        return Fixture(directory:directory,session:session,input:input)
    }
    private func frameCount(_ f: Fixture) throws -> Int {
        let url=f.directory.appendingPathComponent("metrics.json"); try f.session.exportMetrics(to:url)
        return (try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any])["frameUpdates"] as! Int
    }
    func testNearPointerUsesLookCropAndUnchangedDirectionDoesNotRedrawOrPollEarly() throws {
        let f=try fixture(); defer { f.close() }
        f.input.time = .milliseconds(100); f.session.tick()
        XCTAssertEqual(f.session.gazeDirection,4)
        XCTAssertNil(f.session.playback.sample().untilNextFrame)
        let actual=try XCTUnwrap(NSBitmapImageRep(cgImage:XCTUnwrap(f.session.view.image)).colorAt(x:1,y:1)?.usingColorSpace(.deviceRGB))
        let expected=try XCTUnwrap(NSBitmapImageRep(cgImage:f.session.skin.spriteSheet).colorAt(x:33,y:1)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(actual.redComponent,expected.redComponent,accuracy:0.001)
        let count=try frameCount(f)
        f.input.time = .milliseconds(150); f.session.tick()
        XCTAssertEqual(f.input.reads,1)
        f.input.time = .milliseconds(200); f.session.tick()
        XCTAssertEqual(f.input.reads,2); XCTAssertEqual(try frameCount(f),count)
        XCTAssertEqual(f.session.scheduler.pendingCount,1)
    }
    func testLookExpiresWithoutCatchUpAndResumesIdleAtRemainingFrameTime() throws {
        let f=try fixture(); defer { f.close() }
        f.input.time = .milliseconds(100); f.session.tick()
        XCTAssertEqual(f.session.gazeDirection,4)
        f.input.time = .milliseconds(2100); f.session.tick()
        XCTAssertNil(f.session.gazeDirection)
        XCTAssertEqual(f.session.playback.sample().untilNextFrame,.milliseconds(200))
        XCTAssertEqual(f.input.reads,2)
        f.input.time = .seconds(20); f.session.tick(); XCTAssertNil(f.session.gazeDirection)
        f.input.point=CGPoint(x:900,y:900); f.input.time += .milliseconds(100); f.session.tick()
        f.input.point=CGPoint(x:216,y:116); f.input.time += .milliseconds(100); f.session.tick()
        XCTAssertEqual(f.session.gazeDirection,4)
    }
    func testPressPendingClickManualActionAndDragTakePriority() throws {
        let f=try fixture(); defer { f.close() }
        f.input.time = .milliseconds(100); f.session.tick()
        XCTAssertEqual(f.session.gazeDirection,4)
        f.session.view.onDown?(.zero,1)
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertNil(f.session.gazeDirection)
        f.session.view.onUp?(.zero)
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertNil(f.session.gazeDirection)
        f.input.time = f.session.interaction.nextClickDeadline!; f.session.tick()
        XCTAssertEqual(f.session.action,.waving); XCTAssertNil(f.session.gazeDirection)
        f.input.time += .milliseconds(50); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
        f.session.view.onDown?(.zero,1); f.session.view.onMove?(CGPoint(x:20,y:10))
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertNil(f.session.gazeDirection)
        f.session.view.onUp?(CGPoint(x:20,y:10))
        XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:120,y:110))
        f.input.point=CGPoint(x:236,y:126); f.input.time += .milliseconds(100); f.session.tick()
        XCTAssertEqual(f.session.gazeDirection,4)
    }
    func testHiddenSleepingMenuSettingsAndExitStopPointerSampling() throws {
        let f=try fixture(); defer { f.close() }
        for blocker in ["hidden","sleep","menu","settings"] {
            f.input.time += .milliseconds(100); f.session.tick()
            XCTAssertEqual(f.session.gazeDirection,4,blocker)
            switch blocker {
            case "hidden": f.session.setVisible(false)
            case "sleep": f.session.setSleeping(true)
            case "menu": f.session.setMenuOpen(true)
            default: f.session.setSettingsOpen(true)
            }
            let before=f.input.reads
            f.input.time += .seconds(1); f.session.tick()
            XCTAssertNil(f.session.gazeDirection,blocker); XCTAssertEqual(f.input.reads,before,blocker)
            switch blocker {
            case "hidden": XCTAssertEqual(f.session.scheduler.pendingCount,0); f.session.setVisible(true)
            case "sleep": XCTAssertEqual(f.session.scheduler.pendingCount,0); f.session.setSleeping(false)
            case "menu": f.session.setMenuOpen(false)
            default: f.session.setSettingsOpen(false)
            }
        }
        let before=f.input.reads; f.session.prepareToExit()
        f.input.time += .seconds(1); f.session.tick()
        XCTAssertEqual(f.input.reads,before); XCTAssertEqual(f.session.scheduler.pendingCount,0)
    }
    func testDisabledOrUnsupportedSkinsNeverReadPointer() throws {
        for (enabled,support) in [(false,true),(true,false)] {
            let f=try fixture(enabled:enabled,support:support); defer { f.close() }
            for t in [100,200,1000] { f.input.time = .milliseconds(t); f.session.tick() }
            XCTAssertEqual(f.input.reads,0); XCTAssertNil(f.session.gazeDirection)
        }
    }
    func testSettingsTogglePersistsFailureWarnsAndRetryRetainsSkinSelection() throws {
        let f=try fixture(); defer { f.close() }
        let selected=try f.session.library.install(SkinLoader.readPackage(manifestURL:f.directory.appendingPathComponent("default/pet.json")))
        try f.session.useImportedSkin(selected)
        let model=SettingsModel(session:f.session)
        f.input.time = .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
        f.input.failWrites=true; model.setLookAtMouse(false)
        XCTAssertFalse(f.session.preferences.lookAtMouse); XCTAssertNil(f.session.gazeDirection)
        XCTAssertNotNil(model.saveError)
        guard case .loaded(let old)=SettingsStore(url:f.session.settings.url).load() else { return XCTFail("old config") }
        XCTAssertTrue(old.preferences.lookAtMouse)
        f.input.failWrites=false; f.session.retrySave()
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else { return XCTFail("new config") }
        XCTAssertFalse(saved.preferences.lookAtMouse)
        XCTAssertEqual(saved.selectedSkinID,selected.id)
        let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{[]})
        defer { reopened.prepareToExit() }; reopened.start(); XCTAssertFalse(reopened.preferences.lookAtMouse)
        XCTAssertEqual(reopened.selectedSkinID,selected.id)
    }
    func testScaleAndSwitchDiscardOldLookAndUseCurrentWindowCenter() throws {
        let f=try fixture(); defer { f.close() }
        f.input.time = .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
        f.session.setPreferences(.init(scale:2)); XCTAssertNil(f.session.gazeDirection)
        f.input.point=CGPoint(x:132,y:232); f.input.time += .milliseconds(100); f.session.tick()
        XCTAssertEqual(f.session.gazeDirection,0)
        let source=try SkinFixtures.writePackage(in:f.directory.appendingPathComponent("other"))
        let other=try f.session.library.install(SkinLoader.readPackage(manifestURL:source))
        try f.session.useImportedSkin(other)
        let before=f.input.reads; f.input.time += .milliseconds(100); f.session.tick()
        XCTAssertNil(f.session.gazeDirection); XCTAssertEqual(f.input.reads,before)
        try f.session.restoreDefaultSkin()
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,0)
    }
    func testMenuAndSettingsWindowLifecyclePauseAndResumeLook() throws {
        let f=try fixture(); defer { f.close() }
        let status=StatusBarController(session:f.session,onQuit:{})
        defer { status.dispose() }
        f.input.time = .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
        status.menuWillOpen(status.menu)
        let before=f.input.reads
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertEqual(f.input.reads,before)
        status.menuDidClose(status.menu)
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
        status.menu.performActionForItem(at:status.menu.index(of:status.settingsItem))
        let controller=try XCTUnwrap(status.settingsController),during=f.input.reads
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertNil(f.session.gazeDirection); XCTAssertEqual(f.input.reads,during)
        controller.close()
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
    }
}
