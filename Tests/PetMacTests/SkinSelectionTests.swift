import AppKit
import XCTest
import PetCore

@MainActor final class SkinSelectionTests: XCTestCase {
    var directory: URL!, settingsURL: URL!, skin: LoadedSkin!, imported: ImportedSkin!
    override func setUpWithError() throws {
        _=NSApplication.shared
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        settingsURL=directory.appendingPathComponent("settings.json")
        skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory.appendingPathComponent("default")))
        let source=try SkinFixtures.writePackage(in:directory.appendingPathComponent("source"))
        try SkinFixtures.manifest(["id":"alternate","name":"另一个角色","cellWidth":64,"columns":1,"animations":["idle":["durationsMs":[300],"loop":true]]]).write(to:source)
        imported=try SkinLibrary(directory:directory.appendingPathComponent("Skins")).install(SkinLoader.readPackage(manifestURL:source))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    private func makeSession(settings: SettingsStore? = nil) -> PetSession {
        PetSession(skin:skin,now:{.zero},settings:settings ?? SettingsStore(url:settingsURL),screens:{[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:300,height:200),isPrimary:true)]})
    }
    func testRestartLoadsCopiedSkinWithPreferencesAndClampsLargerWindow() throws {
        try SettingsStore(url:settingsURL).save(PetSettings(placement:.init(screenID:"test",origin:CGPoint(x:250,y:150),visibleFrame:CGRect(x:0,y:0,width:300,height:200)),preferences:.init(scale:2,alwaysOnTop:false),selectedSkinID:imported.id))
        try FileManager.default.removeItem(at:directory.appendingPathComponent("source"))
        let session=makeSession(); defer { session.prepareToExit() }
        session.start()
        XCTAssertEqual(session.skin.manifest.name,"另一个角色")
        XCTAssertEqual(session.panel.frame,CGRect(x:172,y:136,width:128,height:64))
        XCTAssertEqual(session.panel.level,.normal)
        XCTAssertEqual(session.view.image?.width,64)
        XCTAssertTrue(session.requestExit())
        guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("settings missing") }
        XCTAssertEqual(saved.selectedSkinID,imported.id)
    }
    func testPreviewThenConfirmCopiesAndSwitchesWithoutRecreatingPanel() async throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start(); session.setPreferences(.init(scale:1.5,alwaysOnTop:false))
        let panel=session.panel, model=SettingsModel(session:session)
        let before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
        await model.previewSkin(at:directory.appendingPathComponent("source/pet.json"))
        XCTAssertEqual(model.candidate?.skin.manifest.id,"alternate")
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
        await model.confirmImport()
        XCTAssertNil(model.skinError); XCTAssertNil(model.candidate)
        XCTAssertTrue(session.panel === panel)
        XCTAssertEqual(session.skin.manifest.id,"alternate")
        XCTAssertEqual(session.panel.frame.size,CGSize(width:96,height:48))
        XCTAssertEqual(session.panel.level,.normal)
        XCTAssertEqual(session.scheduler.pendingCount,1)
        XCTAssertTrue(session.requestExit())
        session.prepareToExit()
        try FileManager.default.removeItem(at:directory.appendingPathComponent("source"))
        let reopened=makeSession(); defer { reopened.prepareToExit() }
        reopened.start()
        XCTAssertEqual(reopened.skin.manifest.id,"alternate")
        XCTAssertEqual(reopened.panel.frame.size,CGSize(width:96,height:48))
    }
    func testInvalidPreviewAndCancellationKeepCurrentCharacterAndSettings() async throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start(); XCTAssertTrue(session.requestExit())
        let original=try Data(contentsOf:settingsURL), model=SettingsModel(session:session)
        let bad=directory.appendingPathComponent("bad/pet.json")
        try FileManager.default.createDirectory(at:bad.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("{broken".utf8).write(to:bad)
        await model.previewSkin(at:bad)
        XCTAssertNotNil(model.skinError); XCTAssertNil(model.candidate)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        await model.previewSkin(at:directory.appendingPathComponent("source/pet.json"))
        XCTAssertNotNil(model.candidate)
        model.cancelSkinSelection(); await model.confirmImport()
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(try Data(contentsOf:settingsURL),original)
    }
    func testSaveFailureRollsBackNewImportAndKeepsCurrentSkin() async throws {
        var fail=false
        let store=SettingsStore(url:settingsURL,write:{ data,url in
            if fail { throw NSError(domain:"disk",code:1) }
            try data.write(to:url,options:.atomic)
        })
        let session=makeSession(settings:store); defer { session.prepareToExit() }
        session.start(); XCTAssertTrue(session.requestExit())
        let original=try Data(contentsOf:settingsURL)
        let model=SettingsModel(session:session), before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
        await model.previewSkin(at:directory.appendingPathComponent("source/pet.json"))
        fail=true; await model.confirmImport()
        XCTAssertNotNil(model.skinError)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(session.view.image?.width,32)
        XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
        fail=false; await model.confirmImport()
        XCTAssertNil(model.skinError); XCTAssertEqual(session.skin.manifest.id,"alternate")
    }
    func testHiddenAndSleepingSwitchKeepsSchedulerPausedAndDefaultRestores() throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start(); session.setVisible(false); session.setSleeping(true)
        session.view.onDown?(.zero,1)
        try session.useImportedSkin(imported)
        XCTAssertFalse(session.panel.isVisible); XCTAssertEqual(session.scheduler.pendingCount,0)
        XCTAssertEqual(session.view.image?.width,64)
        session.setSleeping(false)
        XCTAssertEqual(session.scheduler.pendingCount,0)
        session.setVisible(true)
        XCTAssertEqual(session.scheduler.pendingCount,1)
        try session.restoreDefaultSkin()
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(session.panel.frame.size,CGSize(width:32,height:32))
        guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("settings missing") }
        XCTAssertNil(saved.selectedSkinID)
    }
    func testMissingOrDamagedImportedSkinFallsBackAndWarnsWithoutProtectingValidSettings() throws {
        for damaged in [false,true] {
            let fixture=try sessionImport()
            try SettingsStore(url:settingsURL).save(PetSettings(placement:nil,preferences:.init(scale:0.5),selectedSkinID:fixture.id))
            if damaged { try Data("bad".utf8).write(to:fixture.skin.directory.appendingPathComponent("spritesheet.png")) }
            else { try FileManager.default.removeItem(at:fixture.skin.directory) }
            let session=makeSession(); defer { session.prepareToExit() }
            session.start()
            XCTAssertEqual(session.skin.manifest.id,"my-pet")
            XCTAssertEqual(session.panel.frame.size,CGSize(width:16,height:16))
            XCTAssertNotNil(session.skinWarning)
            let status=StatusBarController(session:session,onQuit:{})
            defer { status.dispose() }
            XCTAssertFalse(status.skinWarningItem.isHidden)
            XCTAssertNotNil(status.skinWarningItem.toolTip)
            XCTAssertFalse(session.protectedSettings)
            XCTAssertTrue(session.requestExit())
            try session.restoreDefaultSkin()
            XCTAssertTrue(status.skinWarningItem.isHidden)
        }
    }
    private func sessionImport() throws -> ImportedSkin {
        try SkinLibrary(directory:directory.appendingPathComponent("Skins")).install(SkinLoader.readPackage(manifestURL:directory.appendingPathComponent("source/pet.json")))
    }
    func testFolderSelectionDoesNotDependOnURLTrailingSlash() async throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start()
        let model=SettingsModel(session:session)
        let folder=URL(fileURLWithPath:directory.appendingPathComponent("source").path,isDirectory:false)
        XCTAssertFalse(folder.hasDirectoryPath)
        await model.previewSkin(at:folder)
        XCTAssertNil(model.skinError)
        XCTAssertEqual(model.candidate?.skin.manifest.id,"alternate")
    }
    func testProtectedSettingsRejectImportAndExitRejectsLateConfirmation() async throws {
        let original=Data("{broken".utf8); try original.write(to:settingsURL)
        let session=makeSession(); defer { session.prepareToExit() }
        session.start()
        let model=SettingsModel(session:session)
        let before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
        await model.previewSkin(at:directory.appendingPathComponent("source/pet.json"))
        await model.confirmImport()
        XCTAssertNotNil(model.skinError)
        XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
        session.prepareToExit(); await model.confirmImport()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
    }
    func testExplicitCLISkinOverridesRememberedSkinAndDefaultButtonUsesBundledSkin() throws {
        let cli=try SkinFixtures.writePackage(in:directory.appendingPathComponent("cli"))
        try SkinFixtures.manifest(["id":"cli-pet"]).write(to:cli)
        try SettingsStore(url:settingsURL).save(PetSettings(placement:nil,selectedSkinID:imported.id))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:cli),defaultSkin:skin,now:{.zero},settings:SettingsStore(url:settingsURL),screens:{[]})
        defer { session.prepareToExit() }
        session.start(restoringSkin:false)
        XCTAssertEqual(session.skin.manifest.id,"cli-pet")
        XCTAssertTrue(session.requestExit())
        guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("settings missing") }
        XCTAssertEqual(saved.selectedSkinID,imported.id)
        try session.restoreDefaultSkin()
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertNil(session.selectedSkinID)
    }
    func testRepeatedConfirmCannotInstallOrScheduleTwice() async throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start()
        let model=SettingsModel(session:session)
        await model.previewSkin(at:directory.appendingPathComponent("source/pet.json"))
        let first=Task { await model.confirmImport() },second=Task { await model.confirmImport() }
        await first.value; await second.value
        XCTAssertNil(model.skinError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path).count,2)
        XCTAssertEqual(session.skin.manifest.id,"alternate")
        XCTAssertEqual(session.scheduler.pendingCount,1)
    }
    func testMetricsIdentifyTheSkinActuallyDisplayedAfterSwitch() throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start(); try session.useImportedSkin(imported)
        let output=directory.appendingPathComponent("metrics.json")
        try session.exportMetrics(to:output)
        let metrics=try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as! [String:Any]
        XCTAssertEqual(metrics["skinID"] as? String,"alternate")
    }
    func testSwitchUsesNewIdleCropAndCancelsPendingClickBeforeDraggingNewSkin() throws {
        let source=directory.appendingPathComponent("source/pet.json")
        try SkinFixtures.manifest(["id":"different-crop","animations":["idle":["startColumn":1,"durationsMs":[400],"loop":true]]]).write(to:source)
        let changed=try SkinLibrary(directory:directory.appendingPathComponent("Skins")).install(SkinLoader.readPackage(manifestURL:source))
        let session=makeSession(); defer { session.prepareToExit() }
        session.start()
        session.view.onDown?(.zero,1); session.view.onUp?(.zero)
        XCTAssertNotNil(session.interaction.nextClickDeadline)
        try session.useImportedSkin(changed)
        XCTAssertNil(session.interaction.nextClickDeadline)
        let pixel=try XCTUnwrap(NSBitmapImageRep(cgImage:XCTUnwrap(session.view.image)).colorAt(x:1,y:1)?.usingColorSpace(.deviceRGB))
        // Compare to the literal second-cell coordinate in the decoded input;
        // device RGB conversion need not preserve the PNG's raw 8-bit value.
        let expected=try XCTUnwrap(NSBitmapImageRep(cgImage:changed.skin.spriteSheet).colorAt(x:33,y:1)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(pixel.redComponent,expected.redComponent,accuracy:0.001)
        XCTAssertLessThan(pixel.redComponent,0.8)
        session.panel.setFrameOrigin(CGPoint(x:100,y:60))
        session.view.onDown?(.zero,1); session.view.onMove?(CGPoint(x:20,y:10)); session.view.onUp?(CGPoint(x:20,y:10))
        XCTAssertEqual(session.panel.frame.origin,CGPoint(x:120,y:70))
        XCTAssertEqual(session.action,.idle)
        guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("settings missing") }
        XCTAssertEqual(saved.selectedSkinID,changed.id)
        XCTAssertEqual(session.scheduler.pendingCount,1)
    }
}
