import AppKit
import XCTest
import PetCore

@MainActor final class FakeChatHost: ChatPresentationHosting {
    var isPresentationVisible = false, hasBlockingSheet = false, hasMarkedInput = false
    var inputSelection = NSRange(location: 0, length: 0)
    var onClose: (() -> Void)?, onVisibility: (() -> Void)?
    var resets = 0, disposed = false, terminating = false
    func setPresentationCallbacks(onClose: @escaping () -> Void, onVisibility: @escaping () -> Void) { self.onClose = onClose; self.onVisibility = onVisibility }
    func presentForHandoff(selection: NSRange) { inputSelection = selection; isPresentationVisible = true; onVisibility?() }
    func hideForHandoff() { isPresentationVisible = false; onVisibility?() }
    func resetLogicalDrafts() { resets += 1 }
    func beginTermination() { terminating = true }
    func cancelTermination() { terminating = false }
    func dispose() { disposed = true; isPresentationVisible = false }
}

@MainActor final class ChatPresentationTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) } }
    func testHandoffKeepsRequestDraftSelectionAndEditor() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }
        try ChatStore(directory: f.root.appendingPathComponent("AI/characters")).save(ChatConversation(characterID: "robin", memories: [ChatMemory(text: "旧记忆")]).appending(user: "旧提问", assistant: "旧回答"))
        try await f.open()
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in XCTFail("managed host must not own presentation") })
        let quick = FakeChatHost(), coordinator = ChatPresentationCoordinator(controller: f.controller, onPresented: { _ in })
        defer { coordinator.dispose() }; coordinator.register(full, for: .full); coordinator.register(quick, for: .quick)
        full.selectPage(2)
        let root = try XCTUnwrap(full.pageScroll.documentView)
        let edit = try XCTUnwrap(descendants(root, NSButton.self).first { $0.title == "编辑" })
        NSApp.sendAction(try XCTUnwrap(edit.action), to: edit.target, from: edit)
        let memory = try XCTUnwrap(descendants(root, NSTextView.self).first { $0.identifier?.rawValue == "memory-editor" })
        memory.string = "未保存记忆编辑"
        f.controller.setDraft("a😀b"); full.render(); full.inputSelection = .init(location: 1, length: 2)
        coordinator.present(.full); f.controller.send(); try await chatEventually { f.client.count == 1 }
        f.client.emit(0, "部分回答"); try await chatEventually { f.controller.partialReply == "部分回答" }
        coordinator.present(.quick)
        XCTAssertTrue(quick.isPresentationVisible); XCTAssertFalse(full.isPresentationVisible); XCTAssertTrue(f.controller.isGenerating)
        XCTAssertEqual(quick.inputSelection, .init(location: 1, length: 2)); XCTAssertEqual(f.controller.draft, "a😀b")
        quick.hasMarkedInput = true; coordinator.present(.full); XCTAssertTrue(quick.isPresentationVisible)
        quick.hasMarkedInput = false; quick.hasBlockingSheet = true; coordinator.present(.full); XCTAssertTrue(quick.isPresentationVisible)
        quick.hasBlockingSheet = false; coordinator.present(.full)
        XCTAssertFalse(quick.isPresentationVisible); XCTAssertTrue(full.isPresentationVisible)
        XCTAssertEqual(full.pages.selectedSegment, 0); XCTAssertEqual(memory.string, "未保存记忆编辑")
        XCTAssertEqual(full.inputSelection, .init(location: 1, length: 2)); XCTAssertEqual(f.client.count, 1)
        f.controller.stop(); full.selectPage(2); full.render(); memory.setMarkedText("组合中", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertTrue(memory.hasMarkedText(), "composition fixture must be real marked text")
        coordinator.present(.quick); XCTAssertTrue(full.isPresentationVisible)
        memory.unmarkText(); coordinator.closeActive(); XCTAssertFalse(f.controller.isGenerating); XCTAssertEqual(memory.string, "")
    }
    func testLateHiddenHostCloseDoesNotCloseCurrentHost() async throws {
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; try await f.open()
        let full = FakeChatHost(), quick = FakeChatHost(); var visible = [Bool]()
        let coordinator = ChatPresentationCoordinator(controller: f.controller, onPresented: { visible.append($0) }); defer { coordinator.dispose() }
        coordinator.register(full, for: .full); coordinator.register(quick, for: .quick); coordinator.present(.full)
        let oldClose = full.onClose, oldVisibility = full.onVisibility
        f.controller.setDraft("请求"); f.controller.send(); try await chatEventually { f.client.count == 1 }
        coordinator.present(.quick); oldClose?(); oldVisibility?()
        XCTAssertTrue(f.controller.isGenerating); XCTAssertTrue(coordinator.isQuickVisible); XCTAssertEqual(visible, [true])
        coordinator.present(.full); oldClose?(); oldVisibility?()
        XCTAssertTrue(f.controller.isGenerating); XCTAssertTrue(full.isPresentationVisible); XCTAssertEqual(visible, [true])
        let close = full.onClose; close?(); close?()
        XCTAssertFalse(f.controller.isGenerating); XCTAssertEqual(full.resets, 1); XCTAssertEqual(quick.resets, 1)
        XCTAssertEqual(visible, [true, false])
        coordinator.present(.quick); coordinator.beginTermination(); XCTAssertTrue(quick.terminating); XCTAssertFalse(f.controller.terminating)
        coordinator.cancelTermination(); XCTAssertFalse(quick.terminating)
    }
}
