import AppKit
import XCTest
import PetCore

@MainActor final class QuickChatWindowTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) } }
    private func event(command: Bool = true) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }
    func testQuickViewSharesComposerAndHandoffWithoutDoubleSending() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; try await f.open()
        let coordinator = ChatPresentationCoordinator(controller: f.controller, onPresented: { _ in }); defer { coordinator.dispose() }
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in })
        let quick = QuickChatWindowController(controller: f.controller, session: pet.session, onExpand: { coordinator.present(.full) }, canDispatch: { true })
        coordinator.register(full, for: .full); coordinator.register(quick, for: .quick); coordinator.present(.quick)
        XCTAssertTrue(quick.window?.canBecomeKey == true); XCTAssertNil(quick.window?.parent)
        quick.composer.keyDown(with: try event(command: false)); XCTAssertTrue(quick.composer.string.contains("\n")); XCTAssertEqual(f.client.count, 0)
        quick.composer.setMarkedText("未提交", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        f.controller.setDraft(quick.composer.string); quick.render(); XCTAssertTrue(quick.composer.hasMarkedText())
        quick.composer.keyDown(with: try event()); coordinator.present(.full); quick.cancelOperation(nil)
        XCTAssertTrue(quick.isPresentationVisible); XCTAssertFalse(full.isPresentationVisible); XCTAssertEqual(f.client.count, 0)
        quick.composer.unmarkText(); quick.composer.string = "a😀b"; quick.composer.didChangeText(); quick.render()
        quick.inputSelection = .init(location: 1, length: 2)
        quick.composer.keyDown(with: try event()); quick.composer.keyDown(with: try event())
        try await chatEventually { f.client.count == 1 }
        f.client.emit(0, "未完句"); try await chatEventually { f.controller.partialReply == "未完句" }
        coordinator.present(.full); XCTAssertTrue(f.controller.isGenerating); XCTAssertEqual(full.inputSelection, .init(location: 1, length: 2))
        coordinator.present(.quick); f.client.propose(0, action: .pauseFocus); try await chatEventually { f.controller.pendingAction != nil }; quick.render()
        let card = try XCTUnwrap(f.controller.pendingAction)
        quick.composer.string = "下一条草稿"; quick.composer.didChangeText(); quick.render()
        coordinator.present(.full); XCTAssertEqual(full.composer.string, "下一条草稿"); XCTAssertEqual(f.controller.pendingAction?.id, card.id)
        coordinator.present(.quick); XCTAssertEqual(quick.composer.string, "下一条草稿"); XCTAssertEqual(f.client.count, 1)
        XCTAssertEqual(try XCTUnwrap(quick.window).contentMinSize, .init(width: 320, height: 240))
    }
    func testLongReplyCardAndErrorRemainReachableAtMinimum() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; try await f.open()
        let quick = QuickChatWindowController(controller: f.controller, session: pet.session, onExpand: {}, canDispatch: { true }); defer { quick.dispose() }
        try await f.send("旧问题", answer: String(repeating: "长回复。", count: 1600), index: 0)
        quick.render(); XCTAssertFalse(quick.transcript.isRichText); XCTAssertTrue(quick.transcript.string.contains("长回复。\n"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            quick.window?.appearance = NSAppearance(named: appearance); quick.window?.setContentSize(.init(width: 320, height: 240)); quick.render()
            quick.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(quick.bodyScroll.hasVerticalScroller)
            XCTAssertGreaterThan(quick.bodyScroll.documentView?.frame.height ?? 0, quick.bodyScroll.contentSize.height)
        }
        quick.bodyScroll.contentView.scroll(to: .zero); quick.bodyScroll.reflectScrolledClipView(quick.bodyScroll.contentView)
        f.controller.setDraft("新一轮"); f.controller.send(); try await chatEventually { f.client.count == 2 }
        f.client.emit(1, "半句话"); try await chatEventually { f.controller.partialReply == "半句话" }; quick.render()
        XCTAssertEqual(quick.bodyScroll.contentView.bounds.minY, 0, accuracy: 1)
        f.client.propose(1, action: .startFocus(minutes: 120)); try await chatEventually { f.controller.pendingAction != nil }; quick.render()
        let root = try XCTUnwrap(quick.bodyScroll.documentView)
        let button = try XCTUnwrap(descendants(root, NSButton.self).first { $0.title == "确认开始" })
        root.scrollToVisible(button.convert(button.bounds, to: root)); quick.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(button.isHidden); XCTAssertTrue(button.isEnabled)
        await f.persistence.failNext("append:robin")
        NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button); await f.controller.waitForPendingWrites(); quick.render()
        XCTAssertTrue(descendants(root, NSTextField.self).contains { $0.stringValue.contains("操作已执行") })
        let retry = try XCTUnwrap(descendants(root, NSButton.self).first { $0.title == "重试本地保存" })
        XCTAssertFalse(retry.isHidden); XCTAssertTrue(retry.isEnabled)
    }
    func testHiddenPetAndFrameEventsDoNotCloseOrTakeFocus() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; try await f.open()
        let quick = QuickChatWindowController(controller: f.controller, session: pet.session, onExpand: {}, canDispatch: { true }); defer { quick.dispose() }
        quick.presentForHandoff(selection: .init(location: 0, length: 0))
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil); defer { other.orderOut(nil) }
        pet.session.setVisible(false); quick.reposition(); XCTAssertTrue(quick.isPresentationVisible); XCTAssertFalse(pet.session.isVisible)
        pet.session.panel.setFrameOrigin(.init(x: 400, y: 300)); quick.reposition()
        XCTAssertTrue(quick.window?.isVisible == true); XCTAssertFalse(quick.window?.isKeyWindow == true)
        XCTAssertNil(quick.window?.parent); XCTAssertFalse(pet.session.panel.canBecomeKey)
        let bytes = try Data(contentsOf: pet.settingsURL)
        quick.window?.setContentSize(.init(width: 400, height: 340)); quick.reposition()
        XCTAssertEqual(try Data(contentsOf: pet.settingsURL), bytes)
    }
}
