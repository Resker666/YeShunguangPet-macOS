import AppKit
import XCTest
import PetCore

@MainActor final class QuickChatIntegrationTests: XCTestCase {
    private func context(_ f: ShortcutFixture) throws -> NSMenu {
        try XCTUnwrap(f.session.view.menu(for: XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.session.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))))
    }
    private func invoke(_ menu: NSMenu, _ title: String) throws {
        let item = try XCTUnwrap(menu.items.first { $0.title == title }); NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
    }
    private func status(_ pet: ShortcutFixture, _ chat: ChatControllerFixture, onQuit: @escaping () -> Void = {}) -> StatusBarController {
        StatusBarController(session: pet.session, updates: .init(currentVersion: ReleaseVersion(tag: "0.4.0")!, architecture: .arm64, client: NoReleaseRequests()), registry: pet.registry, diagnosticWriter: { _ in true }, chat: chat.controller, onQuit: onQuit)
    }
    func testBothMenusOpenCorrectHostAndShareOneRequestGate() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }
        let owner = status(pet, f); defer { owner.dispose() }
        try await chatEventually { f.controller.conversation?.characterID == pet.session.skin.manifest.id }
        let right = try context(pet)
        for menu in [owner.menu, right] {
            try invoke(menu, "快速聊天…"); XCTAssertTrue(owner.chatPresentation?.isQuickVisible == true)
            XCTAssertFalse(owner.chatWindow?.isPresentationVisible == true)
            try invoke(menu, "完整聊天…"); XCTAssertTrue(owner.chatWindow?.isPresentationVisible == true)
            XCTAssertFalse(owner.quickChatWindow?.isPresentationVisible == true)
        }
        pet.session.setVisible(false); try invoke(owner.menu, "快速聊天…")
        XCTAssertFalse(pet.session.isVisible); XCTAssertTrue(owner.chatPresentation?.isQuickVisible == true)
        f.controller.setDraft("同一请求"); f.controller.send(); f.controller.extractMemories()
        try await chatEventually { f.client.count == 1 }; XCTAssertEqual(f.memoryClient.count, 0)
        try invoke(owner.menu, "完整聊天…"); XCTAssertTrue(f.controller.isGenerating)
        f.client.propose(0, action: .setQuiet(enabled: true)); try await chatEventually { f.controller.pendingAction != nil }
        try invoke(owner.menu, "快速聊天…"); f.controller.send(); f.controller.extractMemories()
        XCTAssertEqual(f.client.count, 1); XCTAssertEqual(f.memoryClient.count, 0)
        let revision = pet.session.skinRevision; try pet.session.restoreDefaultSkin()
        try await chatEventually { f.controller.character?.skinRevision == revision + 1 }
        XCTAssertNil(f.controller.pendingAction); XCTAssertEqual(f.controller.conversation?.characterID, pet.session.skin.manifest.id)
    }
    func testEveryGlobalCommandSeesQuickModalAndTermination() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; var quits = 0
        let owner = status(pet, f, onQuit: { quits += 1 }); defer { owner.dispose() }
        try await chatEventually { f.controller.conversation != nil }; owner.startShortcuts()
        owner.shortcuts?.apply(ShortcutFixture.a, to: .toggleQuiet); let hotkey = try XCTUnwrap(pet.registry.registered.keys.first)
        let manifest = try SkinFixtures.writePackage(in: pet.directory.appendingPathComponent("imported"))
        let imported = try pet.session.library.install(SkinLoader.readPackage(manifestURL: manifest))
        let skins = try XCTUnwrap(owner.menu.items.first { $0.title == "切换皮肤" }?.submenu)
        owner.menuWillOpen(skins); try await chatEventually { skins.items.contains { $0.representedObject as? String == imported.id && $0.isEnabled } }; owner.menuDidClose(skins)
        let skinItem = try XCTUnwrap(skins.items.first { $0.representedObject as? String == imported.id })
        let focus = try XCTUnwrap(owner.menu.items.first { $0.title == "专注计时" }?.submenu)
        let start = try XCTUnwrap(focus.items.first { $0.title == "开始专注" })
        try invoke(owner.menu, "快速聊天…"); let quick = try XCTUnwrap(owner.quickChatWindow)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        quick.window?.beginSheet(sheet, completionHandler: { _ in }); XCTAssertTrue(owner.chatPresentation?.hasBlockingSheet == true)
        pet.registry.emit(hotkey); pet.registry.emit(hotkey, down: false); XCTAssertFalse(pet.session.isQuiet)
        NSApp.sendAction(try XCTUnwrap(skinItem.action), to: skinItem.target, from: skinItem)
        NSApp.sendAction(try XCTUnwrap(start.action), to: start.target, from: start)
        XCTAssertNil(pet.session.selectedSkinID); XCTAssertEqual(owner.focus?.status, .ready)
        for command in ["设置…", "使用帮助…", "复制诊断信息", "检查更新…", "完整聊天…", "退出"] { try invoke(owner.menu, command) }
        XCTAssertNil(owner.settingsController); XCTAssertTrue(owner.diagnostics?.feedback.message?.contains("暂不能复制") == true); XCTAssertEqual(quits, 0)
        XCTAssertTrue(quick.isPresentationVisible)
        let delegate = AppDelegate(); delegate.session = pet.session; delegate.status = owner
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel); XCTAssertFalse(f.controller.terminating)
        quick.window?.endSheet(sheet); sheet.orderOut(nil)
        f.controller.setDraft("关闭安静"); f.controller.send(); try await chatEventually { f.client.count == 1 }
        f.client.propose(0, action: .setQuiet(enabled: false)); try await chatEventually { f.controller.pendingAction != nil }
        let card = try XCTUnwrap(f.controller.pendingAction)
        await f.persistence.holdNextWrite(); f.controller.confirmAction(id: card.id, for: card.context)
        await f.persistence.waitForOperations(1)
        let edit = f.controller.memoryEditRevision; owner.beginTermination()
        XCTAssertEqual(f.controller.memoryEditRevision, edit + 1); XCTAssertTrue(f.controller.hasPendingWrites)
        await f.persistence.releaseWrite(); await f.controller.waitForPendingWrites(); owner.cancelTermination()
        XCTAssertNil(f.controller.pendingAction); XCTAssertFalse(f.controller.isGenerating); XCTAssertFalse(f.controller.terminating)
        try invoke(owner.menu, "退出"); XCTAssertEqual(quits, 1)
    }
    func testQuickReplySuppressesOnlyDuplicateBubble() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let manifest = try SkinFixtures.writePackage(in: pet.directory.appendingPathComponent("actions"))
        try SkinFixtures.manifest(["animations": ["idle": ["durationsMs": [300,200], "loop": true], "waving": ["durationsMs": [1000], "loop": false], "jumping": ["durationsMs": [1000], "loop": false]]]).write(to: manifest)
        try pet.session.useImportedSkin(pet.session.library.install(SkinLoader.readPackage(manifestURL: manifest)))
        var preferences = pet.session.preferences; preferences.speechEnabled = true; preferences.positionLocked = true; pet.session.setPreferences(preferences)
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }; let owner = status(pet, f); defer { owner.dispose() }
        try await chatEventually { f.controller.conversation != nil }
        func bubble() -> Bool { pet.session.panel.childWindows?.contains { $0.title == "角色台词" && $0.isVisible } == true }
        try invoke(owner.menu, "快速聊天…"); owner.presentChatReply("普通回复")
        XCTAssertEqual(pet.session.action, .waving); XCTAssertFalse(bubble())
        pet.session.play(.idle); try invoke(owner.menu, "完整聊天…"); owner.presentChatReply("普通回复")
        XCTAssertEqual(pet.session.action, .waving); XCTAssertTrue(bubble())
        pet.session.cancelInput(); pet.session.play(.idle); NSApp.hide(nil)
        defer { NSApp.unhide(nil) }
        try await chatEventually { NSApp.isHidden }
        owner.presentChatReply("隐藏中不能弹出"); XCTAssertFalse(bubble()); XCTAssertTrue(NSApp.isHidden)
        XCTAssertEqual(pet.session.action, .idle)
        NSApp.unhide(nil)
    }
}
