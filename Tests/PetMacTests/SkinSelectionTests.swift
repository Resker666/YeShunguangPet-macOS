import AppKit
import XCTest
@testable import PetCore

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
    func testSettingsRegistersNativeFileDropDestination() throws {
        let session=makeSession(); defer { session.prepareToExit() }
        let controller=makeTestSettingsController(session:session)
        let view=try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL),"settings must accept native Finder file drops")
        XCTAssertFalse(session.view.registeredDraggedTypes.contains(.fileURL),"pet dragging must keep moving the character")
    }
    func testNativeDropCallbacksHighlightAndRouteToSharedPreview() throws {
        let session=makeSession(); session.start()
        let controller=makeTestSettingsController(session:session); controller.present()
        defer { controller.window?.close(); session.prepareToExit() }
        let board=pasteboard([directory.appendingPathComponent("source/pet.json")]); defer { board.releaseGlobally() }
        let view=try XCTUnwrap(controller.window?.contentView), info=SkinDraggingInfo(board:board,window:controller.window)
        XCTAssertEqual(view.draggingEntered(info),.copy)
        XCTAssertTrue(controller.model.isDropTargeted)
        XCTAssertTrue(view.performDragOperation(info),"native view must invoke the real controller drop handler")
        XCTAssertFalse(controller.model.isDropTargeted)
        XCTAssertEqual(view.draggingUpdated(info),[] ,"a queued preview already owns the import entry")
        view.draggingExited(info)
        XCTAssertFalse(controller.model.isDropTargeted)
    }
    private func pasteboard(_ urls:[URL]) -> NSPasteboard {
        let board=NSPasteboard.withUniqueName()
        board.writeObjects(urls.map { $0 as NSURL })
        return board
    }
    func testDroppedZIPFolderAndJSONPreviewBeforeImportAndKeepSourceBytes() async throws {
        let session=makeSession(); session.start()
        let controller=makeTestSettingsController(session:session); controller.present()
        defer { controller.window?.close(); session.prepareToExit() }
        let manifest=directory.appendingPathComponent("source/pet.json"), png=manifest.deletingLastPathComponent().appendingPathComponent("spritesheet.png")
        let json=try Data(contentsOf:manifest), image=try Data(contentsOf:png)
        let archive=directory.appendingPathComponent("角色.zip")
        try ZIPFixtures.archive([.init("下载/角色/pet.json",json),.init("下载/角色/spritesheet.png",image)]).write(to:archive)
        let before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
        for url in [manifest,manifest.deletingLastPathComponent(),archive] {
            let board=pasteboard([url]); defer { board.releaseGlobally() }
            let task=try XCTUnwrap(controller.acceptSkinDrop(from:board)); await task.value
            XCTAssertEqual(controller.model.candidate?.skin.manifest.id,"alternate")
            XCTAssertEqual(session.skin.manifest.id,"my-pet")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
            if url != archive { controller.model.cancelSkinSelection() }
        }
        try FileManager.default.removeItem(at:archive)
        await controller.model.confirmImport()
        XCTAssertNil(controller.model.skinError); XCTAssertEqual(session.skin.manifest.id,"alternate")
        XCTAssertEqual(try Data(contentsOf:session.skin.directory.appendingPathComponent("pet.json")),json)
        XCTAssertEqual(try Data(contentsOf:session.skin.directory.appendingPathComponent("spritesheet.png")),image)
    }
    func testDropRejectsMultipleRemoteAndTextWithoutChangingExistingPreview() async throws {
        let session=makeSession(); session.start()
        let controller=makeTestSettingsController(session:session); controller.present()
        defer { controller.window?.close(); session.prepareToExit() }
        let source=directory.appendingPathComponent("source/pet.json")
        await controller.model.previewSkin(at:source)
        for urls in [[source,source], [URL(string:"https://example.invalid/skin.zip")!], []] {
            let board=pasteboard(urls); defer { board.releaseGlobally() }
            XCTAssertNil(controller.acceptSkinDrop(from:board))
            XCTAssertNotNil(controller.model.skinError)
            XCTAssertEqual(controller.model.candidate?.skin.manifest.id,"alternate")
            XCTAssertEqual(session.skin.manifest.id,"my-pet")
        }
        let board=NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("file:///untrusted.zip",forType:.string)
        XCTAssertNil(controller.acceptSkinDrop(from:board))
        XCTAssertEqual(controller.model.candidate?.skin.manifest.id,"alternate")
    }
    func testPendingDropBlocksSecondDropAndCloseCancelsQueuedPreview() async throws {
        let session=makeSession(); session.start()
        let controller=makeTestSettingsController(session:session); controller.present()
        defer { controller.window?.close(); session.prepareToExit() }
        let board=pasteboard([directory.appendingPathComponent("source/pet.json")]); defer { board.releaseGlobally() }
        let task=try XCTUnwrap(controller.acceptSkinDrop(from:board))
        XCTAssertNil(controller.acceptSkinDrop(from:board))
        controller.window?.close(); await task.value
        XCTAssertNil(controller.model.candidate); XCTAssertFalse(controller.model.hasPendingMutation)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        controller.present(); controller.beginTermination()
        XCTAssertNil(controller.acceptSkinDrop(from:board))
    }
    func testDropIsBlockedWithSheetOrClosedWindowAndBadFileKeepsCurrentSkin() async throws {
        let session=makeSession(); session.start()
        let controller=makeTestSettingsController(session:session)
        defer { controller.window?.close(); session.prepareToExit() }
        let source=directory.appendingPathComponent("source/pet.json"), board=pasteboard([source]); defer { board.releaseGlobally() }
        XCTAssertNil(controller.acceptSkinDrop(from:board))
        controller.present()
        let sheet=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
        controller.window?.beginSheet(sheet,completionHandler:{_ in})
        XCTAssertNil(controller.acceptSkinDrop(from:board))
        controller.window?.endSheet(sheet); sheet.orderOut(nil)
        let bad=directory.appendingPathComponent("unsupported.txt"); try SkinFixtures.manifest([:]).write(to:bad)
        let unsupported=pasteboard([bad]); defer { unsupported.releaseGlobally() }
        let task=try XCTUnwrap(controller.acceptSkinDrop(from:unsupported)); await task.value
        XCTAssertNotNil(controller.model.skinError); XCTAssertNil(controller.model.candidate)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
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
    func testZIPPreviewConfirmationAndRestartUseTheValidatedSnapshot() async throws {
        let json=try Data(contentsOf:directory.appendingPathComponent("source/pet.json")),png=try Data(contentsOf:directory.appendingPathComponent("source/spritesheet.png"))
        let archive=try ZIPFixtures.write([.init("下载/角色/pet.json",json,method:8),.init("下载/角色/spritesheet.png",png,method:8)],to:directory.appendingPathComponent("角色.zip"))
        let session=makeSession();defer{session.prepareToExit()};session.start()
        let model=SettingsModel(session:session),panel=session.panel,before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
        await model.previewSkin(at:archive)
        XCTAssertNil(model.skinError);XCTAssertEqual(model.candidate?.skin.manifest.id,"alternate")
        XCTAssertEqual(session.skin.manifest.id,"my-pet");XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
        if let source=model.candidate?.skin.directory {XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))}
        try FileManager.default.removeItem(at:archive)
        await model.confirmImport()
        XCTAssertNil(model.skinError);XCTAssertNil(model.candidate);XCTAssertTrue(session.panel === panel)
        XCTAssertEqual(session.skin.manifest.id,"alternate");XCTAssertEqual(session.scheduler.pendingCount,1)
        XCTAssertEqual(try Data(contentsOf:session.skin.directory.appendingPathComponent("pet.json")),json)
        XCTAssertEqual(try Data(contentsOf:session.skin.directory.appendingPathComponent("spritesheet.png")),png)
        XCTAssertTrue(session.requestExit());session.prepareToExit()
        let reopened=makeSession();defer{reopened.prepareToExit()};reopened.start();XCTAssertEqual(reopened.skin.manifest.id,"alternate")
    }
    func testAmbiguousZIPAndCancelledPreviewLeaveCurrentCharacterAndSettingsUntouched() async throws {
        let json=try Data(contentsOf:directory.appendingPathComponent("source/pet.json")),png=try Data(contentsOf:directory.appendingPathComponent("source/spritesheet.png"))
        let valid=try ZIPFixtures.write([.init("pet.json",json),.init("spritesheet.png",png)],to:directory.appendingPathComponent("valid.zip"))
        let ambiguous=try ZIPFixtures.write([.init("a/pet.json",json),.init("b/pet.json",json)],to:directory.appendingPathComponent("ambiguous.zip"))
        let session=makeSession();defer{session.prepareToExit()};session.start();XCTAssertTrue(session.requestExit())
        let original=try Data(contentsOf:settingsURL),before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),model=SettingsModel(session:session)
        await model.previewSkin(at:valid);XCTAssertNotNil(model.candidate)
        await model.previewSkin(at:ambiguous);XCTAssertNil(model.candidate);XCTAssertNotNil(model.skinError)
        await model.confirmImport();XCTAssertEqual(session.skin.manifest.id,"my-pet")
        await model.previewSkin(at:valid);model.cancelSkinSelection();await model.confirmImport()
        XCTAssertEqual(try Data(contentsOf:settingsURL),original);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
    }
    func testNormalTerminationWaitsForOutstandingZIPPreview() async throws {
        let zip=try ZIPFixtures.write([.init("pet.json",SkinFixtures.minimalManifest),.init("spritesheet.png",try SkinFixtures.directionalPNG())],to:directory.appendingPathComponent("preview.zip"))
        let started=expectation(description:"ZIP read completed but preview has not returned"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let session=makeSession();defer{session.prepareToExit()};session.start()
        let model=SettingsModel(session:session,previewPackage:{url in
            let result=try SkinLoader.readPackage(manifestURL:url);started.fulfill();release.wait();return result
        })
        let preview=Task{await model.previewSkin(at:zip)}
        let readResult=await XCTWaiter.fulfillment(of:[started],timeout:5)
        XCTAssertEqual(readResult,.completed)
        XCTAssertTrue(model.isBusy);XCTAssertTrue(model.hasPendingMutation)
        model.beginTermination()
        var finished=false
        let waiting=Task{@MainActor in await model.waitForPendingMutations();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        release.signal();await preview.value;await waiting.value
        XCTAssertTrue(finished);XCTAssertFalse(model.hasPendingMutation);XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.candidate);XCTAssertEqual(session.skin.manifest.id,"my-pet")
    }
    func testCancelledPreviewCleanupFailureRemainsAvailableToTermination() async throws {
        let started=expectation(description:"preview cleanup held"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let session=makeSession();defer{session.prepareToExit()};session.start();XCTAssertTrue(session.requestExit())
        let original=try Data(contentsOf:settingsURL)
        let model=SettingsModel(session:session,previewPackage:{url in
            _=try SkinLoader.readPackage(manifestURL:url);started.fulfill();release.wait();throw SkinImportCleanupError(message:"temporary cleanup failed")
        })
        let preview=Task{await model.previewSkin(at:self.directory.appendingPathComponent("source/pet.json"))}
        let readResult=await XCTWaiter.fulfillment(of:[started],timeout:5)
        XCTAssertEqual(readResult,.completed)
        model.beginTermination();release.signal();await model.waitForPendingMutations();await preview.value
        XCTAssertNotNil(model.terminationCleanupError);XCTAssertNil(model.candidate)
        XCTAssertEqual(session.skin.manifest.id,"my-pet");XCTAssertEqual(try Data(contentsOf:settingsURL),original)
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
    func testLibraryListsPriorImportsAndSwitchesWithoutCreatingAnotherCopy() async throws {
        let session=makeSession(); defer { session.prepareToExit() }
        session.start(); let model=SettingsModel(session:session)
        try FileManager.default.removeItem(at:directory.appendingPathComponent("source"))
        await model.reloadLibrary()
        XCTAssertEqual(model.libraryEntries.map(\.id),[imported.id])
        XCTAssertEqual(model.libraryEntries.first?.name,"另一个角色")
        let before=try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
        await model.useSkin(id:imported.id)
        XCTAssertNil(model.skinError)
        XCTAssertEqual(session.skin.manifest.id,"alternate")
        XCTAssertTrue(model.isCurrentSkin(id:imported.id))
        XCTAssertFalse(model.canDeleteSkin(id:imported.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path),before)
        XCTAssertTrue(session.requestExit()); session.prepareToExit()
        let reopened=makeSession(); defer { reopened.prepareToExit() }; reopened.start()
        XCTAssertEqual(reopened.skin.manifest.id,"alternate")
    }
    func testDeletingInactiveCopyKeepsCurrentAndOriginalAssets() async throws {
        let session=makeSession(); defer { session.prepareToExit() }; session.start()
        let model=SettingsModel(session:session)
        await model.useSkin(id:imported.id)
        await model.deleteSkin(id:imported.id)
        XCTAssertNotNil(model.skinError)
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.skin.directory.path))
        model.restoreDefaultSkin()
        await model.deleteSkin(id:imported.id)
        XCTAssertNil(model.skinError)
        XCTAssertFalse(FileManager.default.fileExists(atPath:imported.skin.directory.path))
        XCTAssertTrue(model.libraryEntries.isEmpty)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("source/pet.json").path))
    }
    func testBrokenEntryCanBeRemovedWhileFailedSwitchKeepsCurrentConfig() async throws {
        let session=makeSession(); defer { session.prepareToExit() }; session.start(); XCTAssertTrue(session.requestExit())
        let original=try Data(contentsOf:settingsURL)
        try Data("broken".utf8).write(to:imported.skin.directory.appendingPathComponent("pet.json"))
        let model=SettingsModel(session:session); await model.reloadLibrary()
        XCTAssertNotNil(model.libraryEntries.first?.loadError)
        await model.useSkin(id:imported.id)
        XCTAssertNotNil(model.skinError)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        await model.deleteSkin(id:imported.id)
        XCTAssertNil(model.skinError); XCTAssertTrue(model.libraryEntries.isEmpty)
    }
    func testSaveFailureDuringLibrarySwitchKeepsExistingCopyAndSelection() async throws {
        var fail=false
        let store=SettingsStore(url:settingsURL,write:{ data,url in
            if fail { throw NSError(domain:"disk",code:1) }; try data.write(to:url,options:.atomic)
        })
        let session=makeSession(settings:store); defer { session.prepareToExit() }; session.start(); XCTAssertTrue(session.requestExit())
        let original=try Data(contentsOf:settingsURL),model=SettingsModel(session:session)
        fail=true; await model.useSkin(id:imported.id)
        XCTAssertNotNil(model.skinError)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.skin.directory.path))
    }
    func testProtectedConfigAndRememberedCLISkinCannotBeDeleted() async throws {
        try SettingsStore(url:settingsURL).save(PetSettings(placement:nil,selectedSkinID:imported.id.lowercased()))
        let session=makeSession(); defer { session.prepareToExit() }; session.start(restoringSkin:false)
        let model=SettingsModel(session:session)
        XCTAssertFalse(model.isCurrentSkin(id:imported.id))
        XCTAssertFalse(model.canDeleteSkin(id:imported.id))
        await model.deleteSkin(id:imported.id)
        XCTAssertNotNil(model.skinError)
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.skin.directory.path))
        session.prepareToExit()
        try Data("broken".utf8).write(to:settingsURL)
        let protected=makeSession(); defer { protected.prepareToExit() }; protected.start()
        let protectedModel=SettingsModel(session:protected)
        await protectedModel.deleteSkin(id:imported.id)
        XCTAssertNotNil(protectedModel.skinError)
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.skin.directory.path))
    }
    func testQuitWaitsForImportAndRemovesOnlyItsUncommittedCopy() async throws {
        for afterPublish in [false,true] {
            let session=makeSession(); defer { session.prepareToExit() }; session.start()
            let started=expectation(description:"import paused"),release=DispatchSemaphore(value:0)
            defer { release.signal() }
            let model=SettingsModel(session:session,installPackage:{ library,package in
                if afterPublish {
                    let installed=try library.install(package)
                    started.fulfill(); release.wait(); return installed
                }
                return try library.install(package,writeFile:{ data,url in
                    if url.pathExtension=="png" { started.fulfill(); release.wait() }
                    try data.write(to:url,options:.withoutOverwriting)
                })
            })
            await model.previewSkin(at:directory.appendingPathComponent("source"))
            let confirmation=Task { await model.confirmImport() }
            let startedResult=await XCTWaiter.fulfillment(of:[started],timeout:5)
            XCTAssertEqual(startedResult,.completed)
            XCTAssertTrue(model.hasPendingMutation)
            model.beginTermination()
            let waiter=Task {
                await model.waitForPendingMutations()
                return try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path)
            }
            await Task.yield()
            XCTAssertTrue(model.hasPendingMutation)
            release.signal(); await confirmation.value
            let remaining=try await waiter.value
            XCTAssertEqual(remaining,[imported.id])
            XCTAssertFalse(model.hasPendingMutation)
            XCTAssertNil(model.terminationCleanupError)
            XCTAssertEqual(session.skin.manifest.id,"my-pet")
            XCTAssertNil(session.selectedSkinID)
        }
    }
    func testCancellingQuitAllowsNewOperationsWithoutKeepingOldPreview() async throws {
        let session=makeSession(); defer { session.prepareToExit() }; session.start()
        let model=SettingsModel(session:session)
        await model.previewSkin(at:directory.appendingPathComponent("source"))
        model.beginTermination(); await model.waitForPendingMutations()
        XCTAssertNil(model.candidate)
        await model.useSkin(id:imported.id); await model.deleteSkin(id:imported.id)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.skin.directory.path))
        model.cancelTermination()
        await model.previewSkin(at:directory.appendingPathComponent("source"))
        await model.confirmImport()
        XCTAssertEqual(session.skin.manifest.id,"alternate")
    }
    func testInstallCleanupFailureSurvivesQuitWaitAndCancelledQuit() async throws {
        let session=makeSession(); defer { session.prepareToExit() }; session.start()
        let started=expectation(description:"copy paused"),release=DispatchSemaphore(value:0)
        defer {
            release.signal()
            for child in (try? FileManager.default.contentsOfDirectory(at:session.library.directory,includingPropertiesForKeys:nil)) ?? [] where child.lastPathComponent.hasPrefix(".import-") {
                try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:child.path)
            }
        }
        let model=SettingsModel(session:session,installPackage:{ library,package in
            try library.install(package,writeFile:{ data,url in
                if url.pathExtension=="png" {
                    started.fulfill(); release.wait()
                    try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:url.deletingLastPathComponent().path)
                    throw SkinError("磁盘写入失败")
                }
                try data.write(to:url,options:.withoutOverwriting)
            })
        })
        await model.previewSkin(at:directory.appendingPathComponent("source"))
        let task=Task { await model.confirmImport() }
        let result=await XCTWaiter.fulfillment(of:[started],timeout:5)
        XCTAssertEqual(result,.completed)
        model.beginTermination(); release.signal()
        await model.waitForPendingMutations(); await task.value
        XCTAssertNotNil(model.terminationCleanupError)
        XCTAssertEqual(session.skin.manifest.id,"my-pet")
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.skin.directory.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:session.library.directory.path).contains{$0.hasPrefix(".import-")})
        model.cancelTermination(); model.beginTermination()
        XCTAssertNotNil(model.terminationCleanupError)
    }
}

@MainActor private final class SkinDraggingInfo: NSObject,NSDraggingInfo {
    let draggingPasteboard:NSPasteboard
    let draggingDestinationWindow:NSWindow?
    var draggingSourceOperationMask:NSDragOperation = .copy
    var draggingLocation:NSPoint { .zero }
    var draggedImageLocation:NSPoint { .zero }
    nonisolated var draggedImage:NSImage? { nil }
    var draggingSource:Any? { nil }
    var draggingSequenceNumber:Int { 1 }
    var draggingFormation:NSDraggingFormation = .none
    var animatesToDestination=false
    var numberOfValidItemsForDrop=1
    var springLoadingHighlight:NSSpringLoadingHighlight { .none }
    init(board:NSPasteboard,window:NSWindow?) { draggingPasteboard=board; draggingDestinationWindow=window }
    func slideDraggedImage(to screenPoint:NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
}
