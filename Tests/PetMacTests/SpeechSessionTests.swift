import AppKit
import XCTest
import PetCore

@MainActor private final class SpeechInput {
    var time=Duration.zero
    var screens=[ScreenArea(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]
}
@MainActor final class SpeechSessionTests:XCTestCase {
    @MainActor private struct Fixture {
        let directory:URL,session:PetSession,input:SpeechInput
        func close(){session.prepareToExit();try? FileManager.default.removeItem(at:directory)}
    }
    private func fixture(enabled:Bool=true,lines:[String:Any]?=["click":["你好"],"drag":["搬家了"]]) throws -> Fixture {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),input=SpeechInput()
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("skin"))
        var fields:[String:Any]=["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["durationsMs":[1000],"loop":false],"jumping":["durationsMs":[1000],"loop":false]]]
        if let lines{fields["speech"]=lines}
        try SkinFixtures.manifest(fields).write(to:manifest)
        let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
        try store.save(.init(placement:nil,preferences:.init(alwaysOnTop:false,lookAtMouse:false,speechEnabled:enabled)))
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:store,screens:{input.screens})
        session.start();session.panel.setFrameOrigin(CGPoint(x:100,y:100))
        return .init(directory:directory,session:session,input:input)
    }
    private func bubble(_ f:Fixture)->NSWindow? {f.session.panel.childWindows?.first{$0.title=="角色台词" && $0.isVisible}}
    private func text(_ window:NSWindow)->String? {window.contentView?.subviews.compactMap{$0 as? NSTextField}.first?.stringValue}
    private func click(_ f:Fixture) {f.session.view.onDown?(.zero,1);f.session.view.onUp?(.zero);f.input.time += .seconds(1);f.session.tick()}
    func testSingleClickShowsPassiveBubbleForSixSecondsUsingTheExistingScheduler() throws {
        let f=try fixture();defer{f.close()};click(f)
        let window=try XCTUnwrap(bubble(f))
        XCTAssertEqual(text(window),"你好");XCTAssertFalse(window.canBecomeKey);XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.ignoresMouseEvents);XCTAssertEqual(window.level,.normal)
        XCTAssertTrue(CGRect(x:0,y:0,width:1000,height:700).contains(window.frame));XCTAssertFalse(window.frame.intersects(f.session.panel.frame))
        XCTAssertEqual(f.session.scheduler.pendingCount,1)
        f.input.time = .milliseconds(6999);f.session.tick();XCTAssertNotNil(bubble(f))
        f.input.time = .seconds(7);f.session.tick();XCTAssertNil(bubble(f));XCTAssertEqual(f.session.scheduler.pendingCount,1)
    }
    func testDisabledSpeechStaysSilentAndSettingsEnablePersistsAcrossRestart() throws {
        let f=try fixture(enabled:false);defer{f.close()};click(f);XCTAssertNil(bubble(f))
        let model=SettingsModel(session:f.session);model.setSpeechEnabled(true)
        XCTAssertTrue(model.preferences.speechEnabled)
        guard case .loaded(let saved)=SettingsStore(url:f.session.settings.url).load() else{return XCTFail("speech not saved")}
        XCTAssertTrue(saved.preferences.speechEnabled)
        let reopened=PetSession(skin:f.session.skin,now:{.zero},settings:SettingsStore(url:f.session.settings.url),screens:{f.session.screens()})
        defer{reopened.prepareToExit()};reopened.start();XCTAssertTrue(reopened.preferences.speechEnabled)
    }
    func testLegacyFallbackAndExplicitEmptyLinesHaveDifferentBehavior() throws {
        for (lines,expected) in [(nil,true),(["click":[],"drag":[]],false)] as [([String:Any]?,Bool)] {
            let f=try fixture(lines:lines);defer{f.close()};click(f)
            XCTAssertEqual(bubble(f) != nil,expected)
            if let window=bubble(f){XCTAssertFalse(try XCTUnwrap(text(window)).isEmpty)}
        }
    }
    func testDragHonorsGlobalCooldownAndDoubleClickDoesNotConsumeIt() throws {
        let f=try fixture();defer{f.close()}
        f.session.view.onDown?(.zero,2);f.session.view.onUp?(.zero);f.input.time = .seconds(1);f.session.tick();XCTAssertNil(bubble(f))
        click(f);XCTAssertEqual(text(try XCTUnwrap(bubble(f))),"你好")
        f.session.view.onDown?(.zero,1);f.session.view.onMove?(CGPoint(x:20,y:10));f.session.view.onUp?(CGPoint(x:20,y:10));XCTAssertNil(bubble(f))
        f.input.time = .seconds(32)
        f.session.view.onDown?(.zero,1);f.session.view.onMove?(CGPoint(x:20,y:10));f.session.view.onUp?(CGPoint(x:20,y:10))
        XCTAssertEqual(text(try XCTUnwrap(bubble(f))),"搬家了")
    }
    func testQuietMenusSettingsAndLifecycleDismissAndCannotResurrectOldBubble() throws {
        for blocker in ["quiet","menu","settings","hidden","sleep","display","skin","disable","exit"] {
            let f=try fixture();defer{f.close()};click(f);XCTAssertNotNil(bubble(f),blocker)
            switch blocker {
            case "quiet":f.session.setQuiet(true)
            case "menu":f.session.setMenuOpen(true)
            case "settings":f.session.setSettingsOpen(true)
            case "hidden":f.session.setVisible(false);f.session.setVisible(true)
            case "sleep":f.session.setSleeping(true);f.session.setSleeping(false)
            case "display":f.session.screensChanged()
            case "skin":try f.session.restoreDefaultSkin()
            case "disable":var value=f.session.preferences;value.speechEnabled=false;f.session.setPreferences(value)
            default:f.session.prepareToExit()
            }
            XCTAssertNil(bubble(f),blocker);f.input.time += .seconds(1);f.session.tick();XCTAssertNil(bubble(f),blocker)
        }
    }
    func testQuietModeSuppressesNewSpeechWhileManualClickStillAnimates() throws {
        let f=try fixture();defer{f.close()};f.session.setQuiet(true);click(f)
        XCTAssertEqual(f.session.action,.waving);XCTAssertNil(bubble(f))
        f.session.setQuiet(false);click(f);XCTAssertNotNil(bubble(f))
    }
    func testFailedPlacementDoesNotConsumeSpeechCooldown() throws {
        let f=try fixture();defer{f.close()}
        f.input.screens=[.init(id:"test",visibleFrame:CGRect(x:0,y:0,width:80,height:80),isPrimary:true)]
        f.session.panel.setFrameOrigin(CGPoint(x:20,y:20));click(f);XCTAssertNil(bubble(f))
        f.input.screens=[.init(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]
        f.session.screensChanged();click(f)
        XCTAssertEqual(text(try XCTUnwrap(bubble(f))),"你好")
    }
}
