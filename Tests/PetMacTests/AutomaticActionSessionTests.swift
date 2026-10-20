import AppKit
import XCTest
import PetCore

@MainActor private final class AutomaticInput { var time=Duration.zero,reads=0,failWrites=false }
@MainActor final class AutomaticActionSessionTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL,session: PetSession,input: AutomaticInput
        func close() { session.prepareToExit(); try? FileManager.default.removeItem(at:directory) }
    }
    private func fixture(gaze: Bool = false, rules: [[String:Any]]? = [["action":"waving","cooldownSeconds":5]]) throws -> Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("default"))
        let behavior:Any=rules.map { ["rules":$0] as Any } ?? NSNull()
        try SkinFixtures.manifest(["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["startColumn":1,"durationsMs":[1000],"loop":false],"jumping":["durationsMs":[5000],"loop":false]],"lookDirections":(0..<16).map{_ in ["row":0,"column":0]},"behavior":behavior]).write(to:manifest)
        let input=AutomaticInput()
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"),write:{ data,url in
            if input.failWrites { throw SkinError("write failed") }; try data.write(to:url,options:.atomic)
        })
        try store.save(.init(placement:nil,preferences:.init(lookAtMouse:gaze,automaticActions:true)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]},pointerPosition:{ input.reads += 1; return CGPoint(x:216,y:116) },automaticRandom:{0})
        session.start(); session.panel.setFrameOrigin(CGPoint(x:100,y:100))
        return Fixture(directory:directory,session:session,input:input)
    }
    private func metrics(_ f: Fixture) throws -> [String:Any] {
        let url=f.directory.appendingPathComponent("metrics.json"); try f.session.exportMetrics(to:url)
        return try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    }
    func testAutomaticActionSupersedesGazeAndFinishesBackToIdleWithOneTimer() throws {
        let f=try fixture(gaze:true); defer { f.close() }
        f.input.time = .milliseconds(44900); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
        f.input.time = .seconds(45); f.session.tick()
        XCTAssertEqual(f.session.action,.waving); XCTAssertNil(f.session.gazeDirection)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,1)
        let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(f.session.view.image))
        var pixel=[Int](repeating:0,count:4); bitmap.getPixel(&pixel,atX:1,y:1)
        XCTAssertEqual(pixel[0],128)
        XCTAssertEqual(f.session.scheduler.pendingCount,1)
        f.input.time = .seconds(46); f.session.tick(); XCTAssertEqual(f.session.action,.idle)
        f.input.time = .milliseconds(46100); f.session.tick(); XCTAssertEqual(f.session.gazeDirection,4)
    }
    func testManualActionPressPendingClickAndDragTakePriority() throws {
        let f=try fixture(); defer { f.close() }
        f.input.time = .seconds(44); f.session.play(.jumping)
        for time in [45,48] { f.input.time = .seconds(time); f.session.tick(); XCTAssertEqual(f.session.action,.jumping) }
        f.input.time = .seconds(49); f.session.tick(); XCTAssertEqual(f.session.action,.idle)
        f.input.time = .seconds(50); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
        f.session.view.onDown?(.zero,1); XCTAssertEqual(f.session.action,.idle)
        f.input.time = .seconds(100); f.session.tick(); XCTAssertEqual(f.session.action,.idle)
        f.session.view.onMove?(CGPoint(x:20,y:10)); f.session.view.onUp?(CGPoint(x:20,y:10))
        XCTAssertEqual(f.session.panel.frame.origin,CGPoint(x:120,y:110))
        f.session.view.onDown?(.zero,1); f.session.view.onUp?(.zero)
        f.input.time += .milliseconds(100); f.session.tick(); XCTAssertEqual(f.session.action,.idle)
        f.input.time = f.session.interaction.nextClickDeadline!; f.session.tick()
        XCTAssertEqual(f.session.action,.waving)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,1)
    }
    func testMenuSettingsHiddenSleepAndExitFreezeAutomaticWaitWithoutPointerPolling() throws {
        for blocker in ["menu","settings","hidden","sleep"] {
            let f=try fixture(); defer { f.close() }
            f.input.time = .seconds(10)
            switch blocker {
            case "menu": f.session.setMenuOpen(true)
            case "settings": f.session.setSettingsOpen(true)
            case "hidden": f.session.setVisible(false)
            default: f.session.setSleeping(true)
            }
            f.input.time = .seconds(1000); f.session.tick(); XCTAssertEqual(f.session.action,.idle,blocker)
            XCTAssertEqual(f.input.reads,0,blocker)
            if blocker=="hidden" || blocker=="sleep" { XCTAssertEqual(f.session.scheduler.pendingCount,0) }
            switch blocker {
            case "menu": f.session.setMenuOpen(false)
            case "settings": f.session.setSettingsOpen(false)
            case "hidden": f.session.setVisible(true)
            default: f.session.setSleeping(false)
            }
            f.input.time = .seconds(1034); f.session.tick(); XCTAssertEqual(f.session.action,.idle,blocker)
            f.input.time = .seconds(1035); f.session.tick(); XCTAssertEqual(f.session.action,.waving,blocker)
            f.session.prepareToExit(); f.input.time = .seconds(2000); f.session.tick()
            XCTAssertEqual(f.session.scheduler.pendingCount,0)
        }
    }
    func testDisableCancelsOnlyAutomaticActionAndKeepsManualGesture() throws {
        let f=try fixture(); defer { f.close() }
        f.input.time = .seconds(45); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
        var preferences=f.session.preferences; preferences.automaticActions=false; f.session.setPreferences(preferences)
        XCTAssertEqual(f.session.action,.idle)
        f.input.time = .seconds(500); f.session.tick(); XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,1)
        preferences.automaticActions=true; f.session.setPreferences(preferences)
        f.session.play(.jumping); preferences.automaticActions=false; f.session.setPreferences(preferences)
        XCTAssertEqual(f.session.action,.jumping)
    }
    func testSameSkinPreservesCooldownButDifferentSkinResetsIt() throws {
        let f=try fixture(rules:[["action":"waving","cooldownSeconds":3600]]); defer { f.close() }
        let imported=try f.session.library.install(SkinLoader.readPackage(manifestURL:f.directory.appendingPathComponent("default/pet.json")))
        try f.session.useImportedSkin(imported)
        f.input.time = .seconds(45); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
        f.input.time = .seconds(46); f.session.tick()
        try f.session.useImportedSkin(imported)
        f.input.time = .seconds(100); f.session.tick(); XCTAssertEqual(f.session.action,.idle)
        try f.session.restoreDefaultSkin()
        f.input.time = .seconds(145); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
    }
    func testSettingsControlsPersistIntervalAndRetryFailureWithoutLosingSkin() throws {
        let f=try fixture(); defer { f.close() }
        let imported=try f.session.library.install(SkinLoader.readPackage(manifestURL:f.directory.appendingPathComponent("default/pet.json")))
        try f.session.useImportedSkin(imported)
        let model=SettingsModel(session:f.session)
        model.setAutomaticActionInterval(15); model.setAutomaticActions(false)
        f.input.failWrites=true; model.setAutomaticActions(true)
        XCTAssertNotNil(model.saveError); XCTAssertTrue(f.session.preferences.automaticActions)
        guard case .loaded(let old)=SettingsStore(url:f.session.settings.url).load() else { return XCTFail("saved config missing") }
        XCTAssertFalse(old.preferences.automaticActions)
        f.input.failWrites=false; f.session.retrySave()
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else { return XCTFail("retry missing") }
        XCTAssertTrue(saved.preferences.automaticActions); XCTAssertEqual(saved.preferences.automaticActionIntervalSeconds,15)
        XCTAssertEqual(saved.selectedSkinID,imported.id)
        model.setAutomaticActionInterval(14); XCTAssertEqual(f.session.preferences.automaticActionIntervalSeconds,15)
    }
    func testExplicitEmptyRulesNeverStartOrReadPointer() throws {
        let f=try fixture(rules:[]); defer { f.close() }
        f.input.time = .seconds(500); f.session.tick()
        XCTAssertEqual(f.session.action,.idle); XCTAssertEqual(f.input.reads,0)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,0)
    }
    func testReloadedLegacySkinRebuildsChangedFallbackCandidates() throws {
        let f=try fixture(rules:nil); defer { f.close() }
        let imported=try f.session.library.install(SkinLoader.readPackage(manifestURL:f.directory.appendingPathComponent("default/pet.json")))
        try f.session.useImportedSkin(imported)
        f.input.time = .seconds(45); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
        f.input.time = .seconds(46); f.session.tick()
        let url=imported.skin.directory.appendingPathComponent("pet.json")
        var object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        var animations=object["animations"] as! [String:[String:Any]]
        animations.removeValue(forKey:"waving"); object["animations"]=animations
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        try f.session.useImportedSkin(.init(id:imported.id,skin:f.session.library.load(id:imported.id)))
        f.input.time = .seconds(91); f.session.tick(); XCTAssertEqual(f.session.action,.jumping)
        f.input.time = .seconds(96); f.session.tick()
        // Four legal frames cross the 30-second automatic-action limit.
        object["cellWidth"]=16; object["columns"]=4
        animations["jumping"]=["durationsMs":[10000,10000,10000,20],"loop":false]; object["animations"]=animations
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        try f.session.useImportedSkin(.init(id:imported.id,skin:f.session.library.load(id:imported.id)))
        f.input.time = .seconds(200); f.session.tick(); XCTAssertEqual(f.session.action,.idle)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,2)
        animations["waving"]=["startColumn":1,"durationsMs":[1000],"loop":false]; object["animations"]=animations
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        try f.session.useImportedSkin(.init(id:imported.id,skin:f.session.library.load(id:imported.id)))
        f.input.time = .seconds(245); f.session.tick(); XCTAssertEqual(f.session.action,.waving)
        XCTAssertEqual(try metrics(f)["automaticActionCount"] as? Int,3)
    }
}
