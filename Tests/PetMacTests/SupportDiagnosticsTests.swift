import AppKit
import XCTest
import PetCore

@MainActor final class SupportDiagnosticsTests:XCTestCase {
    func testReportOnlyIncludesValidatedMetadataAndFiniteGeometry() {
        var snapshot=SupportDiagnosticSnapshot()
        snapshot.version="0.1.20";snapshot.build="21";snapshot.commit=String(repeating:"a",count:40)
        snapshot.architecture = .x86_64;snapshot.systemVersion = .init(majorVersion:14,minorVersion:8,patchVersion:9)
        snapshot.screens=[CGRect(x:-1920,y:76,width:1920,height:974)]
        snapshot.pet = .init(frame:CGRect(x:-48,y:124,width:192,height:208),visible:true)
        snapshot.configuration = .protectedFile;snapshot.skin = .imported
        let text=snapshot.report()
        XCTAssertTrue(text.contains("0.1.20"));XCTAssertTrue(text.contains("21"));XCTAssertTrue(text.contains("14.8.9"));XCTAssertTrue(text.contains("x86_64"))
        XCTAssertTrue(text.contains("x=-1920.0"));XCTAssertTrue(text.contains("x=-48.0"));XCTAssertTrue(text.contains("原配置受保护"))
        snapshot.version="/Users/secret-owner";snapshot.build="PRIVATE-BUILD";snapshot.commit="TOKEN\nprivate"
        snapshot.screens=[CGRect(x:CGFloat.nan,y:0,width:10,height:10)]
        let rejected=snapshot.report()
        for secret in ["secret-owner","PRIVATE-BUILD","TOKEN","private","nan","inf"] {XCTAssertFalse(rejected.contains(secret),rejected)}
        XCTAssertTrue(rejected.contains("不可用"))
    }
    func testCaptureDoesNotCopyPersonalFieldsPathsIdentifiersOrRawErrors()throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("PRIVATE-OWNER-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let manifest=try SkinFixtures.writePackage(in:root)
        try SkinFixtures.manifest(["id":"private-skin-id","name":"PRIVATE-SKIN-NAME","description":"PRIVATE-DESCRIPTION"]).write(to:manifest)
        let skin=try SkinLoader.load(manifestURL:manifest)
        let url=root.appendingPathComponent("PRIVATE-CONFIG.json")
        var originalPreferences=PetPreferences()
        originalPreferences.speechOverrides["private-skin-id"] = .init(click:["PRIVATE-SPEECH"],drag:[],focusCompleted:[],breakCompleted:[])
        try SettingsStore(url:url).save(.init(placement:nil,preferences:originalPreferences))
        var writes=0
        let store=SettingsStore(url:url,write:{_,_ in writes+=1;throw NSError(domain:"PRIVATE-DOMAIN",code:4,userInfo:[NSLocalizedDescriptionKey:"PRIVATE-ERROR /Users/private-owner/token"])})
        let session=PetSession(skin:skin,now:{.zero},settings:store,screens:{[ScreenArea(id:"PRIVATE-SCREEN-ID",visibleFrame:CGRect(x:0,y:76,width:1000,height:700),isPrimary:true)]})
        defer{session.prepareToExit()};session.start()
        var preferences=session.preferences
        XCTAssertEqual(preferences.speechOverrides["private-skin-id"]?.click,["PRIVATE-SPEECH"])
        preferences.alwaysOnTop.toggle()
        session.setPreferences(preferences)
        XCTAssertTrue(session.persistenceError?.contains("PRIVATE-ERROR")==true)
        let before=try Data(contentsOf:url),writesBefore=writes
        let snapshot=SupportDiagnosticSnapshot.capture(session:session,focusWindow:nil)
        XCTAssertEqual(snapshot.configuration,.saveFailed)
        let text=snapshot.report()
        for secret in ["PRIVATE-","private-skin-id","private-owner","/Users/",root.path,"speechOverrides","keyboardShortcuts"] {XCTAssertFalse(text.contains(secret),text)}
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(writes,writesBefore,"diagnostics must not retry the failed save")
    }
    func testCopyIsManualFreshAndUsesOnlyAnIsolatedPasteboard()throws {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        board.setString("clipboard-before",forType:.string)
        var version="0.1.20",captures=0
        let model=SupportDiagnosticsModel(capture:{captures+=1;var s=SupportDiagnosticSnapshot();s.version=version;return s},canCopy:{true},write:{SupportDiagnosticsModel.write($0,to:board)})
        XCTAssertEqual(captures,0);XCTAssertEqual(board.string(forType:.string),"clipboard-before")
        model.copyDiagnostics();XCTAssertEqual(model.feedback,.copied);XCTAssertEqual(captures,1)
        XCTAssertTrue(try XCTUnwrap(board.string(forType:.string)).contains("0.1.20"))
        version="0.1.21";model.copyDiagnostics();XCTAssertEqual(captures,2)
        let next=try XCTUnwrap(board.string(forType:.string));XCTAssertTrue(next.contains("0.1.21"));XCTAssertFalse(next.contains("0.1.20"))
    }
    func testBlockedCopyLeavesClipboardUntouchedAndFailureCanRetry() {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.setString("original",forType:.string)
        var allowed=false,writeFails=true,captures=0
        let model=SupportDiagnosticsModel(capture:{captures+=1;return .init()},canCopy:{allowed},write:{text in writeFails ? false : SupportDiagnosticsModel.write(text,to:board)})
        model.copyDiagnostics();XCTAssertEqual(model.feedback,.blocked);XCTAssertEqual(captures,0);XCTAssertEqual(board.string(forType:.string),"original")
        allowed=true;model.copyDiagnostics();XCTAssertEqual(model.feedback,.failed);XCTAssertEqual(board.string(forType:.string),"original")
        writeFails=false;model.copyDiagnostics();XCTAssertEqual(model.feedback,.copied);XCTAssertNotEqual(board.string(forType:.string),"original")
    }
    func testUnavailableSessionAndProtectedConfigurationRemainDiagnosable()throws {
        let missing=SupportDiagnosticSnapshot.capture(session:nil,focusWindow:nil)
        XCTAssertEqual(missing.configuration,.unavailable);XCTAssertTrue(missing.report().contains("会话未启动"))
        let f=try ShortcutFixture(corrupt:true);defer{f.close()};let before=try Data(contentsOf:f.settingsURL)
        let report=SupportDiagnosticSnapshot.capture(session:f.session,focusWindow:nil)
        XCTAssertEqual(report.configuration,.protectedFile);XCTAssertEqual(try Data(contentsOf:f.settingsURL),before)
    }
    func testCommandLineSkinIsNotMisreportedAsBundled()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let external=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:f.directory.appendingPathComponent("external")))
        let session=PetSession(skin:external,defaultSkin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.directory.appendingPathComponent("external-settings.json")),screens:f.session.screens)
        defer{session.prepareToExit()};session.start()
        XCTAssertEqual(SupportDiagnosticSnapshot.capture(session:session,focusWindow:nil).skin,.external)
    }
}
