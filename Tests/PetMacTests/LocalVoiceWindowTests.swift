import AppKit
import XCTest
import PetCore

@MainActor final class LocalVoiceWindowTests: XCTestCase {
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) } }
    func testLocalVoiceControlsAreSharedReadOnlyOnOpenAndReachableAtMinimumSize() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
        f.controller.configureVoice(services: .init(input: input, output: output), now: { .zero })
        let model = try XCTUnwrap(f.controller.localVoices)
        try await chatEventually { model.isLoaded }
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present(); full.selectPage(4)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            full.window?.appearance = NSAppearance(named: appearance); full.window?.setContentSize(.init(width: 440, height: 420)); full.render()
            let buttons = descendants(full.pageScroll, NSButton.self)
            for title in ["导入语音包…", "应用当前角色音色", "刷新本地语音库", "应用语音设置"] { XCTAssertNotNil(buttons.first { $0.title == title }) }
            XCTAssertGreaterThan(full.pageScroll.documentView?.frame.height ?? 0, full.pageScroll.contentSize.height)
            XCTAssertTrue(full.pageScroll.hasVerticalScroller)
        }
        XCTAssertEqual(input.permissionRequests, 0); XCTAssertTrue(output.spoken.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("LocalVoice").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("AI/voice.json").path))
        await f.close()
    }
    func testClosingWindowCancelsUnconfirmedImportAndKeepsVoiceOff() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        f.controller.configureVoice(services: .init(input: ControlledVoiceInput(), output: ControlledVoiceOutput()), now: { .zero })
        let model = try XCTUnwrap(f.controller.localVoices)
        try await chatEventually { model.isLoaded }
        model.preview(folder: try LocalVoiceFixtures.folder(f.root))
        try await chatEventually { model.preview != nil }
        let stage = try XCTUnwrap(model.preview)
        f.controller.windowClosed(); await model.waitForPendingMutations()
        XCTAssertNil(model.preview); XCTAssertTrue(model.index.packages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.privateDirectory.path))
        XCTAssertFalse(f.controller.voice?.settings.enabledForSession == true)
        await f.close()
    }
    func testDamagedUnboundVoiceCanBeSelectedForDeletionButCannotBeApplied() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        f.controller.configureVoice(services: .init(input: ControlledVoiceInput(), output: ControlledVoiceOutput()), now: { .zero })
        let model = try XCTUnwrap(f.controller.localVoices)
        try await chatEventually { model.isLoaded }
        model.preview(folder: try LocalVoiceFixtures.folder(f.root)); try await chatEventually { model.preview != nil }
        model.confirmImport(); await model.waitForPendingMutations()
        let id = try XCTUnwrap(model.index.packages.first?.id)
        try Data().write(to: f.root.appendingPathComponent("LocalVoice/Voices/" + id.uuidString + "/reference.wav"))
        model.refresh(); await model.waitForPendingMutations()
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present(); full.selectPage(4); full.render()
        let local = try XCTUnwrap(descendants(full.pageScroll, ChatLocalVoiceSettingsView.self).first)
        let popup = try XCTUnwrap(descendants(local, NSPopUpButton.self).first)
        let item = try XCTUnwrap(popup.itemArray.first { $0.representedObject as? String == id.uuidString })
        XCTAssertTrue(item.isEnabled, "must remain manageable for deletion")
        popup.select(item); NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
        let buttons = descendants(local, NSButton.self)
        XCTAssertFalse(try XCTUnwrap(buttons.first { $0.title == "应用当前角色音色" }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == "删除选中语音包…" }).isEnabled)
        let before = await f.persistence.operations.count
        model.applyBinding(id, expected: try XCTUnwrap(f.controller.character)); await model.waitForPendingMutations()
        let after = await f.persistence.operations.count
        XCTAssertEqual(after, before); XCTAssertFalse(model.hasUnsaved)
        await f.close()
    }
    func testLongDuplicateNamesKeepControlsReachableInBothAppearances() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        f.controller.configureVoice(services: .init(input: ControlledVoiceInput(), output: ControlledVoiceOutput()), now: { .zero })
        let model = try XCTUnwrap(f.controller.localVoices)
        try await chatEventually { model.isLoaded }
        for id in ["voice-one", "voice-two"] {
            let folder = try LocalVoiceFixtures.folder(f.root, id: id)
            try LocalVoiceFixtures.manifest { $0["id"] = id; $0["name"] = String(repeating: "很长", count: 40) }.write(to: folder.appendingPathComponent("voice.json"))
            model.preview(folder: folder); try await chatEventually { model.preview != nil }
            model.confirmImport(); await model.waitForPendingMutations()
        }
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present(); full.selectPage(4)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/local-character-voice-validation/ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            full.window?.appearance = NSAppearance(named: appearance); full.window?.setContentSize(.init(width: 440, height: 420)); full.render()
            full.window?.contentView?.layoutSubtreeIfNeeded()
            let local = try XCTUnwrap(descendants(full.pageScroll, ChatLocalVoiceSettingsView.self).first)
            XCTAssertEqual(full.window?.contentView?.bounds.width ?? 0, 440, accuracy: 1)
            XCTAssertLessThanOrEqual(local.bounds.width, full.pageScroll.contentSize.width)
            let popup = try XCTUnwrap(descendants(local, NSPopUpButton.self).first)
            XCTAssertEqual(popup.numberOfItems, 3); XCTAssertNotEqual(popup.itemTitle(at: 1), popup.itemTitle(at: 2))
            let button = try XCTUnwrap(descendants(local, NSButton.self).first { $0.title == "删除选中语音包…" })
            _ = button.scrollToVisible(button.bounds)
            let document = try XCTUnwrap(full.pageScroll.documentView)
            XCTAssertTrue(button.convert(button.bounds, to: document).intersects(full.pageScroll.documentVisibleRect))
            full.window?.displayIfNeeded()
            let visible = try XCTUnwrap(full.window?.contentView)
            let bitmap = try XCTUnwrap(visible.bitmapImageRepForCachingDisplay(in: visible.bounds))
            visible.cacheDisplay(in: visible.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("local-voice-" + name + ".png"))
        }
        await f.close()
    }
}
