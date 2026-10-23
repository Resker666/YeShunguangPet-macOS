import AppKit
import XCTest
import PetCore

@MainActor private final class ChatPauseInput { var time=Duration.zero; var reads=0 }

@MainActor final class ChatIntegrationTests: XCTestCase {
    func testTwoChatEntriesShareOneController() async throws {
        let f = try ShortcutFixture(); defer { f.close() }
        let chat = try ChatControllerFixture(); try await chat.open()
        let status = StatusBarController(session:f.session,updates:ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:"0.1.22")!,architecture:.arm64,client:NoReleaseRequests()),registry:f.registry,chat:chat.controller,onQuit:{})
        let first = try XCTUnwrap(status.menu.items.first { $0.title == "聊天…" })
        status.menu.performActionForItem(at:status.menu.index(of:first))
        let window = try XCTUnwrap(status.chatWindow)
        XCTAssertTrue(window.window?.isVisible == true)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.session.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
        let context = try XCTUnwrap(f.session.view.menu(for:event))
        let second = try XCTUnwrap(context.items.first { $0.title == "聊天…" })
        context.performActionForItem(at:context.index(of:second))
        XCTAssertTrue(status.chatWindow === window)
        let sheet = NSWindow(contentRect:.init(x:0,y:0,width:100,height:100),styleMask:.titled,backing:.buffered,defer:false)
        window.window?.beginSheet(sheet,completionHandler:{_ in})
        XCTAssertNil(f.session.view.menu(for:event))
        window.window?.endSheet(sheet); sheet.orderOut(nil)
        status.beginTermination(); XCTAssertFalse(chat.controller.canSend)
        status.cancelTermination(); XCTAssertFalse(chat.controller.isGenerating)
        status.dispose(); await chat.close()
    }
    func testChatAndSettingsPauseSourcesAreIndependent() throws {
        _ = NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input=ChatPauseInput()
        let manifest=try SkinFixtures.writePackage(in:directory)
        try SkinFixtures.manifest(["lookDirections":(0..<16).map { ["row":0,"column":$0 == 4 ? 1 : 0] }]).write(to:manifest)
        let session=PetSession(skin:try SkinLoader.load(manifestURL:manifest),now:{input.time},settings:SettingsStore(url:directory.appendingPathComponent("settings.json")),screens:{[.init(id:"test",visibleFrame:CGRect(x:0,y:0,width:1000,height:700),isPrimary:true)]},pointerPosition:{input.reads += 1;return CGPoint(x:216,y:116)})
        defer { session.prepareToExit();try? FileManager.default.removeItem(at:directory) }
        session.start();session.panel.setFrameOrigin(CGPoint(x:100,y:100))
        input.time = .milliseconds(100);session.tick();XCTAssertEqual(session.gazeDirection,4)
        session.setSettingsOpen(true);session.setChatPresented(true)
        let reads=input.reads
        session.setSettingsOpen(false);input.time += .milliseconds(100);session.tick()
        XCTAssertNil(session.gazeDirection);XCTAssertEqual(input.reads,reads)
        session.setSettingsOpen(true);session.setChatPresented(false)
        input.time += .milliseconds(100);session.tick();XCTAssertNil(session.gazeDirection);XCTAssertEqual(input.reads,reads)
        session.setSettingsOpen(false);input.time += .milliseconds(100);session.tick();XCTAssertEqual(session.gazeDirection,4)
        session.setChatPresented(true)
        session.view.onDown?(.zero,1);session.view.onMove?(CGPoint(x:20,y:0));session.view.onUp?(CGPoint(x:20,y:0))
        XCTAssertFalse(session.interaction.isPointerBusy) // manual drag still completes
        session.setFocusQuiet(true);session.setChatPresented(false);XCTAssertTrue(session.focusQuiet)
    }
    func testReplyFeedbackHonorsAllGates() throws {
        let f = try ShortcutFixture(); defer { f.close() }
        let manifest = try SkinFixtures.writePackage(in:f.directory.appendingPathComponent("actions"))
        try SkinFixtures.manifest(["animations":["idle":["durationsMs":[300,200],"loop":true],"waving":["durationsMs":[1000],"loop":false],"jumping":["durationsMs":[1000],"loop":false]]]).write(to:manifest)
        try f.session.useImportedSkin(f.session.library.install(SkinLoader.readPackage(manifestURL:manifest)))
        var prefs = f.session.preferences; prefs.speechEnabled = true; prefs.positionLocked = true
        f.session.setPreferences(prefs); f.session.panel.setFrameOrigin(CGPoint(x:100,y:100))
        f.session.setChatPresented(true)
        f.session.presentChatReply(String(repeating:"你好🌼\n",count:40))
        XCTAssertEqual(f.session.action,.waving)
        let bubble = try XCTUnwrap(f.session.panel.childWindows?.first { $0.title == "角色台词" && $0.isVisible })
        let text = try XCTUnwrap(bubble.contentView?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue)
        XCTAssertLessThanOrEqual(text.utf16.count,80); XCTAssertFalse(text.contains("\n"))
        for blocker in ["quiet","focus","menu","settings","pointer","action","hidden","sleep"] {
            f.session.play(.idle)
            switch blocker {
            case "quiet": f.session.setQuiet(true)
            case "focus": f.session.setFocusQuiet(true)
            case "menu": f.session.setMenuOpen(true)
            case "settings": f.session.setSettingsOpen(true)
            case "pointer": f.session.view.onDown?(.zero,1)
            case "action": f.session.play(.jumping)
            case "hidden": f.session.setVisible(false)
            default: f.session.setSleeping(true)
            }
            let previous = f.session.action
            f.session.presentChatReply("不能出现")
            XCTAssertEqual(f.session.action,previous,blocker)
            XCTAssertFalse(f.session.panel.childWindows?.contains { $0.title == "角色台词" && $0.isVisible } == true,blocker)
            f.session.setQuiet(false); f.session.setFocusQuiet(false); f.session.setMenuOpen(false); f.session.setSettingsOpen(false)
            f.session.cancelInput(); f.session.setSleeping(false); f.session.setVisible(true)
        }
        f.session.play(.idle); prefs.speechEnabled = false; f.session.setPreferences(prefs)
        f.session.presentChatReply("挥手但无台词"); XCTAssertEqual(f.session.action,.waving)
        XCTAssertFalse(f.session.panel.childWindows?.contains { $0.title == "角色台词" && $0.isVisible } == true)
    }
    func testSkinRevisionOnlyChangesAfterSuccessfulCommit() throws {
        let f = try ShortcutFixture(); defer { f.close() }
        let revision = f.session.skinRevision
        f.input.writeFails = true
        XCTAssertThrowsError(try f.session.restoreDefaultSkin())
        XCTAssertEqual(f.session.skinRevision,revision)
        f.input.writeFails = false; try f.session.restoreDefaultSkin()
        XCTAssertEqual(f.session.skinRevision,revision + 1)
        f.session.presentChatReply("missing waving falls back")
        XCTAssertEqual(f.session.action,.idle)
    }
}
