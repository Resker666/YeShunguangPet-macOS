import AppKit
import XCTest
import PetCore

@MainActor private final class MarkedChatComposer: ChatComposer {
    var marked = false
    override func hasMarkedText() -> Bool { marked }
}
@MainActor final class ChatWindowTests: XCTestCase {
    func testCommandEnterHonorsMarkedText() throws {
        _ = NSApplication.shared
        let text = MarkedChatComposer(frame: CGRect(x:0,y:0,width:300,height:80))
        var sends = 0
        text.onSend = { sends += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        text.marked = true; text.keyDown(with:event); XCTAssertEqual(sends,0)
        text.marked = false; text.keyDown(with:event); XCTAssertEqual(sends,1)
        text.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)))
        XCTAssertTrue(text.string.contains("\n")); XCTAssertEqual(sends,1)
    }
    func testWindowLayoutAndPlainText() async throws {
        let f = try ChatControllerFixture(); defer { }
        try await f.open()
        let pasteboard = NSPasteboard.withUniqueName()
        let window = ChatWindowController(controller:f.controller,onPresentationChange:{_ in},copyText:{pasteboard.clearContents();return pasteboard.setString($0,forType:.string)})
        let native = try XCTUnwrap(window.window)
        XCTAssertEqual(native.contentLayoutRect.size,CGSize(width:520,height:620))
        XCTAssertEqual(native.contentMinSize,CGSize(width:440,height:420))
        XCTAssertEqual(window.pages.segmentCount,4)
        try await f.send("你好",answer:"<script>alert('literal')</script>\n" + String(repeating:"长回复",count:100),index:0)
        window.render()
        XCTAssertFalse(window.transcript.isRichText)
        XCTAssertTrue(window.transcript.string.contains("<script>"))
        window.copyReply()
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType:.string)).hasPrefix("<script>"))
        XCTAssertFalse(native.isVisible) // receiving a reply cannot open a window
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            native.appearance = NSAppearance(named:appearance)
            native.setContentSize(native.contentMinSize)
            for page in 0..<4 {
                window.selectPage(page)
                native.contentView?.layoutSubtreeIfNeeded()
                XCTAssertTrue(window.pageScroll.hasVerticalScroller)
                XCTAssertGreaterThanOrEqual(window.pageScroll.documentView?.frame.height ?? 0,window.pageScroll.contentSize.height)
            }
        }
        window.present(); window.windowDidMiniaturize(Notification(name:NSWindow.didMiniaturizeNotification))
        window.close(); XCTAssertFalse(f.controller.isGenerating)
        window.dispose(); pasteboard.releaseGlobally()
        await f.close()
    }
    func testProfileConfirmationAndConnectionRetryKeepFrozenTargets() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let old = try XCTUnwrap(f.controller.character)
        f.controller.activate(.init(id:"march7",name:"三月七",description:"",skinRevision:1))
        try await chatEventually { f.controller.conversation?.characterID == "march7" }
        f.controller.applyProfile(.init(background:"wrong"),for:old)
        f.controller.clearHistory(for:old)
        XCTAssertTrue(f.controller.conversation?.profile.background != "wrong")
        await f.persistence.failNext("connection")
        f.controller.saveConnection(.init(enabled:false,model:.pro))
        try await chatEventually { f.controller.connectionError != nil }
        XCTAssertTrue(f.controller.canRetryConnectionSave)
        f.controller.retryConnectionSave()
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.connection,.init(enabled:false,model:.pro))
        XCTAssertNil(f.controller.connectionError)
        await f.close()
    }
    private func descendants<T:NSView>(_ view:NSView,_ type:T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0,type) }
    }
    func testDelayedArchivePopulatesPersonaOnceAndPreservesUnappliedEdits() async throws {
        let f=try ChatControllerFixture();try await f.open()
        let profile=ChatProfile(background:"saved background",personality:"saved personality",speakingStyle:"saved style",examples:"saved examples")
        _ = try await f.persistence.worker.apply(.profile(characterID:"march7",profile:profile))
        let window=ChatWindowController(controller:f.controller,onPresentationChange:{_ in})
        window.selectPage(1)
        await f.persistence.holdNextLoad("march7")
        f.controller.activate(.init(id:"march7",name:"三月七",description:"",skinRevision:1))
        await f.persistence.waitForLoad("march7");window.render()
        XCTAssertNil(f.controller.conversation)
        await f.persistence.releaseLoad("march7")
        try await chatEventually { f.controller.conversation != nil };window.render()
        let fields=descendants(try XCTUnwrap(window.pageScroll.documentView),NSTextView.self)
        XCTAssertEqual(fields.count,4)
        XCTAssertEqual(fields[0].string,profile.background)
        XCTAssertEqual(fields[1].string,profile.personality)
        fields[1].string="edited personality";window.render()
        XCTAssertEqual(fields[1].string,"edited personality")
        let apply=try XCTUnwrap(descendants(try XCTUnwrap(window.pageScroll.documentView),NSButton.self).first { $0.title == "应用人设" })
        NSApp.sendAction(try XCTUnwrap(apply.action),to:apply.target,from:apply)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.profile.background,profile.background)
        XCTAssertEqual(f.controller.conversation?.profile.personality,"edited personality")
        window.dispose();await f.close()
    }
    func testSendButtonCannotTransmitNativeMarkedText() async throws {
        let f=try ChatControllerFixture();try await f.open()
        let window=ChatWindowController(controller:f.controller,onPresentationChange:{_ in})
        window.composer.setMarkedText("尚未确认",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(window.composer.hasMarkedText())
        f.controller.setDraft(window.composer.string);window.render()
        let button=try XCTUnwrap(descendants(try XCTUnwrap(window.pageScroll.documentView),NSButton.self).first { $0.title.hasPrefix("发送") })
        XCTAssertFalse(button.isEnabled)
        NSApp.sendAction(try XCTUnwrap(button.action),to:button.target,from:button)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.client.count,0)
        window.composer.unmarkText();f.controller.setDraft("已确认");window.render()
        NSApp.sendAction(try XCTUnwrap(button.action),to:button.target,from:button)
        try await chatEventually { f.client.count == 1 }
        window.close();window.dispose();await f.close()
    }
    func testDisablingAIDuringCredentialSaveIsImmediateAndPersisted() async throws {
        let f=try ChatControllerFixture();try await f.open()
        await f.credentials.holdNextSave()
        f.controller.saveCredential("NEW-TEST-ONLY")
        await f.credentials.waitForSave()
        f.controller.saveConnection(.init(enabled:false))
        XCTAssertFalse(f.controller.connection.enabled)
        await f.credentials.releaseSave();await f.controller.waitForPendingWrites()
        XCTAssertFalse(f.controller.connection.enabled)
        guard case .loaded(let saved)=await ChatArchiveWorker(settingsURL:f.root.appendingPathComponent("settings.json")).loadConnection() else { return XCTFail("missing") }
        XCTAssertFalse(saved.enabled)
        await f.close()
    }
    func testDisablingAIQueuesBehindPreferenceWriteAndOldReceiptCannotReenable() async throws {
        let f=try ChatControllerFixture();try await f.open()
        await f.persistence.holdNextWrite()
        f.controller.saveConnection(.init(enabled:true,model:.pro))
        await f.persistence.waitForOperations(1)
        f.controller.saveConnection(.init(enabled:false,model:.pro))
        XCTAssertFalse(f.controller.connection.enabled)
        await f.persistence.holdNextWrite();await f.persistence.releaseWrite()
        let deadline=ContinuousClock.now + .seconds(3)
        while await f.persistence.operations.count < 2 && f.controller.hasPendingWrites && ContinuousClock.now < deadline { await Task.yield() }
        let operations=await f.persistence.operations
        XCTAssertEqual(operations.count,2)
        XCTAssertFalse(f.controller.connection.enabled)
        await f.persistence.releaseWrite();await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.connection,.init(enabled:false,model:.pro))
        await f.close()
    }

}
