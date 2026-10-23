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
        XCTAssertEqual(window.pages.segmentCount,3)
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
            for page in 0..<3 {
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
}
