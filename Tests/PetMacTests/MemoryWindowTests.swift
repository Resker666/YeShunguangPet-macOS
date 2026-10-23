import AppKit
import XCTest
import PetCore

@MainActor final class MemoryWindowTests: XCTestCase {
    private func fixture(open: Bool = true, canDispatch: @escaping () -> Bool = { true }) async throws -> ChatControllerFixture {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(canDispatch: canDispatch); addTeardownBlock { await f.close() }
        let state = try ChatConversation(characterID: "robin", memories: [ChatMemory(text: "已存记忆")]).appending(user: "用户原话依据", assistant: "助手文字")
        try ChatStore(directory: f.root.appendingPathComponent("AI/characters")).save(state)
        if open { try await f.open() }
        return f
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    private func button(_ root: NSView, _ title: String) throws -> NSButton {
        try XCTUnwrap(descendants(root, NSButton.self).first { $0.title == title })
    }
    private func click(_ button: NSButton) throws { NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button) }
    private func editor(_ root: NSView) throws -> NSTextView {
        try XCTUnwrap(descendants(root, NSTextView.self).first { $0.identifier?.rawValue == "memory-editor" })
    }
    private func review(_ f: ChatControllerFixture) async throws {
        f.controller.extractMemories(); try await chatEventually { f.memoryClient.count == 1 }
        f.memoryClient.complete(0, json: #"{"candidates":[{"text":"新的候选","sourceRounds":[1]}]}"#)
        try await chatEventually { f.controller.memoryReview != nil }
    }
    func testFourPagesAndAsyncArchiveLoadNeverOverwriteEditor() async throws {
        let f = try await fixture(open: false)
        await f.persistence.holdNextLoad("robin")
        f.controller.activate(.init(id: "robin", name: "知更鸟", description: "", skinRevision: 0))
        await f.persistence.waitForLoad("robin")
        let window = ChatWindowController(controller: f.controller, onPresentationChange: { _ in })
        defer { window.dispose() }
        XCTAssertEqual(window.pages.segmentCount, 4)
        window.selectPage(2)
        await f.persistence.releaseLoad("robin")
        try await chatEventually { f.controller.conversation != nil }; window.render()
        let root = try XCTUnwrap(window.pageScroll.documentView)
        XCTAssertTrue(descendants(root, NSTextField.self).contains { $0.stringValue == "已存记忆" })
        try click(button(root, "编辑"))
        let field = try editor(root); field.string = "未应用草稿"
        f.controller.setDraft("其他状态刷新"); window.render()
        XCTAssertEqual(field.string, "未应用草稿")
        try await f.open("robin", revision: 1); window.render()
        XCTAssertEqual(try editor(root).string, "")
        try click(button(root, "编辑")); XCTAssertEqual(try editor(root).string, "已存记忆")
        window.windowWillClose(Notification(name: NSWindow.willCloseNotification)); window.render()
        XCTAssertEqual(try editor(root).string, "")
    }
    func testMemorySaveRejectsMarkedTextAtActionBoundary() async throws {
        let f = try await fixture()
        let view = ChatMemoryView(controller: f.controller, hasBlockingModal: { false }, confirm: { _, _, action in action() })
        view.render(); try click(button(view, "编辑"))
        let field = try editor(view)
        field.setMarkedText("尚未提交", selectedRange: .init(location: 4, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        view.render(); let save = try button(view, "保存修改")
        XCTAssertFalse(save.isEnabled); try click(save)
        XCTAssertFalse(f.controller.hasPendingWrites)
        field.unmarkText(); field.string = "确认修改"; view.render(); try click(save)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.memories.first?.text, "确认修改")
        try await review(f); view.render()
        let candidate = try XCTUnwrap(descendants(view, NSTextView.self).first { $0.identifier?.rawValue.hasPrefix("memory-candidate-") == true })
        let check = try button(view, "保存此条"); check.state = .on; try click(check)
        candidate.setMarkedText("候选组合", selectedRange: .init(location: 4, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        view.render(); let accept = try button(view, "保存所选")
        XCTAssertFalse(accept.isEnabled); try click(accept); XCTAssertFalse(f.controller.hasPendingWrites)
        candidate.unmarkText(); candidate.string = "已确认候选"; view.render(); try click(accept)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.memories.last?.text, "已确认候选")
    }
    func testDeleteDispatchesOnlyAfterModalEndsAndRevalidatesContext() async throws {
        let modal = ChatTestFlag()
        let f = try await fixture(canDispatch: { !modal.value })
        var confirmation: (() -> Void)?
        let view = ChatMemoryView(controller: f.controller, hasBlockingModal: { modal.value }, confirm: { _, _, action in modal.value = true; confirmation = action })
        view.render(); try click(button(view, "删除"))
        confirmation?(); XCTAssertFalse(f.controller.hasPendingWrites)
        f.controller.setDraft("不发送"); XCTAssertFalse(f.controller.canSend); XCTAssertFalse(f.controller.canExtractMemories)
        modal.value = false; try await f.open("hutao"); confirmation?()
        XCTAssertFalse(f.controller.hasPendingWrites)
        try await f.open(); view.render(); try click(button(view, "删除"))
        f.controller.setSleeping(true); modal.value = false; confirmation?()
        XCTAssertFalse(f.controller.hasPendingWrites)
        f.controller.setSleeping(false); view.render(); try click(button(view, "删除"))
        modal.value = false; confirmation?(); await f.controller.waitForPendingWrites()
        XCTAssertTrue(f.controller.conversation?.memories.isEmpty == true)
    }
    func testReviewSelectionSourcesAndFailureRecovery() async throws {
        let f = try await fixture()
        let view = ChatMemoryView(controller: f.controller, hasBlockingModal: { false }, confirm: { _, _, action in action() })
        try await review(f); view.render()
        let check = try button(view, "保存此条"); XCTAssertEqual(check.state, .off)
        try click(button(view, "查看来源"))
        XCTAssertTrue(descendants(view, NSTextField.self).contains { $0.stringValue.contains("用户原话依据") && !$0.isHidden })
        let candidate = try XCTUnwrap(descendants(view, NSTextView.self).first { $0.identifier?.rawValue.hasPrefix("memory-candidate-") == true })
        candidate.string = "人工修改后的候选"; candidate.didChangeText()
        check.state = .on; try click(check)
        await f.persistence.failNext("memories:robin")
        view.render(); try click(button(view, "保存所选")); await f.controller.waitForPendingWrites(); view.render()
        XCTAssertTrue(try button(view, "重试本地保存").isEnabled)
        f.controller.windowClosed(); view.render()
        try click(button(view, "重试本地保存")); await f.controller.waitForPendingWrites(); view.render()
        XCTAssertEqual(f.controller.conversation?.memories.last?.text, "人工修改后的候选")
        XCTAssertEqual(f.memoryClient.count, 1)
        f.controller.saveConnection(.init(enabled: false)); await f.controller.waitForPendingWrites(); view.render()
        XCTAssertTrue(try button(view, "编辑").isEnabled)
        XCTAssertFalse(try button(view, "提炼记忆").isEnabled)
    }
    func testClearAndTerminationDiscardUnconfirmedMemoryEditor() async throws {
        let f = try await fixture()
        let view = ChatMemoryView(controller: f.controller, hasBlockingModal: { false }, confirm: { _, _, action in action() })
        view.render(); try click(button(view, "编辑"))
        let field = try editor(view); field.string = "未保存编辑"
        await f.persistence.failNext("clear:robin")
        f.controller.clearHistory(); await f.controller.waitForPendingWrites(); view.render()
        XCTAssertEqual(field.string, "未保存编辑", "failed clear keeps draft")
        f.controller.clearHistory(); await f.controller.waitForPendingWrites(); view.render()
        XCTAssertEqual(field.string, "", "successful clear resets unsaved editor")
        try click(button(view, "编辑")); field.string = "退出前编辑"
        f.controller.beginTermination(); f.controller.cancelTermination(); view.render()
        XCTAssertEqual(field.string, "", "cancelled exit does not revive unsaved editor")
    }

}
