import AppKit
import XCTest
import PetCore

@MainActor final class ChatActionWindowTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) } }
    func testNativeActionCardUsesTypedProposalAndStaleButtonsDoNothing() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; try await f.open()
        let modal = ChatTestFlag(), view = ChatActionCardView(controller: f.controller, hasBlockingModal: { modal.value })
        f.controller.setDraft("专注25分钟"); f.controller.send(); try await chatEventually { f.client.count == 1 }
        f.client.emit(0, "已成功开始（不可信）"); f.client.propose(0, action: .startFocus(minutes: 25))
        try await chatEventually { f.controller.pendingAction != nil }; view.render()
        let text = descendants(view, NSTextField.self).map(\.stringValue).joined()
        for value in ["25", "常用", "尚未执行"] { XCTAssertTrue(text.contains(value)) }
        XCTAssertFalse(text.contains("不可信")); XCTAssertTrue(f.actions.executions.isEmpty)
        let confirm = try XCTUnwrap(descendants(view, NSButton.self).first { $0.title == "确认开始" })
        modal.value = true; view.render(); XCTAssertFalse(confirm.isEnabled)
        NSApp.sendAction(try XCTUnwrap(confirm.action), to: confirm.target, from: confirm); XCTAssertTrue(f.actions.executions.isEmpty)
        modal.value = false; view.render(); await f.persistence.failNext("append:robin")
        NSApp.sendAction(try XCTUnwrap(confirm.action), to: confirm.target, from: confirm)
        NSApp.sendAction(try XCTUnwrap(confirm.action), to: confirm.target, from: confirm)
        await f.controller.waitForPendingWrites(); view.render()
        XCTAssertEqual(f.actions.executions, [.startFocus(minutes: 25)]); XCTAssertTrue(view.isHidden)
        XCTAssertEqual(f.controller.state, .unsaved)
        f.controller.retryPendingSave(); await f.controller.waitForPendingWrites(); XCTAssertEqual(f.actions.executions.count, 1)
        NSApp.sendAction(try XCTUnwrap(confirm.action), to: confirm.target, from: confirm); XCTAssertEqual(f.actions.executions.count, 1)
        f.controller.setDraft("新请求"); f.controller.send(); try await chatEventually { f.client.count == 2 }
        f.client.propose(1, action: .setQuiet(enabled: false)); try await chatEventually { f.controller.pendingAction != nil }; view.render()
        NSApp.sendAction(try XCTUnwrap(confirm.action), to: confirm.target, from: confirm); XCTAssertEqual(f.actions.executions.count, 1)
        XCTAssertNotNil(f.controller.pendingAction)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }; full.render()
        let nativeRoot = try XCTUnwrap(full.pageScroll.documentView)
        XCTAssertTrue(descendants(nativeRoot, NSTextField.self).contains { $0.stringValue.contains("尚未执行") })
        XCTAssertFalse(full.transcript.string.contains("不可信"))
    }
}
