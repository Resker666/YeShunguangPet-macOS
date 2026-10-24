import AppKit
import XCTest
import PetCore

@MainActor final class VoiceProductionIntegrationTests: XCTestCase {
    private func status(_ pet: ShortcutFixture, _ chat: ChatControllerFixture) -> StatusBarController {
        StatusBarController(session: pet.session, updates: .init(currentVersion: ReleaseVersion(tag: "0.5.0")!, architecture: .arm64, client: NoReleaseRequests()), registry: pet.registry, chat: chat.controller, onQuit: {})
    }
    func testProductionVoiceIsLazyAndUsesOneSharedOwner() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); try await f.open()
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
        f.controller.configureVoice(services: .init(input: input, output: output), now: { .zero })
        let original = try XCTUnwrap(f.controller.voice)
        let bar = status(pet, f); defer { bar.dispose() }
        bar.openQuickChat(); bar.chatPresentation?.present(.full); bar.chatWindow?.selectPage(4)
        try await chatEventually { original.settings.isLoaded }
        XCTAssertTrue(bar.chatWindow?.controller.voice === original); XCTAssertTrue(bar.quickChatWindow?.controller.voice === original)
        XCTAssertEqual(input.permissionRequests, 0); XCTAssertTrue(input.starts.isEmpty); XCTAssertTrue(output.spoken.isEmpty)
        let operations = await f.persistence.operations; XCTAssertTrue(operations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("AI/voice.json").path))
        await f.close()
    }
    func testDefaultProductionInstallsDisabledVoiceWithoutWriting() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let bar = StatusBarController(session: pet.session, updates: .init(currentVersion: ReleaseVersion(tag: "0.5.0")!, architecture: .arm64, client: NoReleaseRequests()), registry: pet.registry, onQuit: {})
        defer { bar.dispose() }
        let voice = try XCTUnwrap(bar.chat?.voice)
        try await chatEventually { voice.settings.isLoaded }
        XCTAssertFalse(voice.settings.enabledForSession); XCTAssertFalse(voice.hasActivity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pet.directory.appendingPathComponent("AI/voice.json").path))
    }
    func testMenuQuietAndSheetStopVoiceButPetHideKeepsIt() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); try await f.open()
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
        f.controller.configureVoice(services: .init(input: input, output: output), now: { .zero })
        let voice = try XCTUnwrap(f.controller.voice), bar = status(pet, f); defer { bar.dispose() }
        try await chatEventually { voice.settings.isLoaded && f.controller.conversation != nil }
        voice.settings.apply(.init(enabled: true)); await f.controller.waitForPendingWrites()
        bar.openQuickChat(); voice.readLatest("回复"); try await chatEventually { voice.isSpeaking }
        pet.session.setVisible(false); bar.refresh(); XCTAssertTrue(voice.isSpeaking)
        pet.session.setQuiet(true); XCTAssertFalse(voice.isSpeaking)
        pet.session.setQuiet(false); voice.readLatest("第二段"); try await chatEventually { voice.isSpeaking }
        bar.menuWillOpen(bar.menu); XCTAssertFalse(voice.isSpeaking); bar.menuDidClose(bar.menu)
        voice.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { input.starts.count == 1 }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 180, height: 80), styleMask: .titled, backing: .buffered, defer: false)
        let window = try XCTUnwrap(bar.quickChatWindow?.window)
        window.beginSheet(sheet, completionHandler: { _ in }); try await chatEventually { !voice.blocksChat }
        window.endSheet(sheet); sheet.orderOut(nil)
        XCTAssertEqual(output.spoken.count, 2); XCTAssertEqual(input.starts.count, 1)
        await f.close()
    }
    func testSettingsSheetRejectsInternalQuickHandoff() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); try await f.open(); let bar = status(pet, f); defer { bar.dispose() }
        bar.chatPresentation?.present(.full)
        let item = bar.settingsItem
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let parent = try XCTUnwrap(bar.settingsController?.window)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 180, height: 80), styleMask: .titled, backing: .buffered, defer: false)
        parent.beginSheet(sheet, completionHandler: { _ in }); defer { parent.endSheet(sheet); sheet.orderOut(nil) }
        bar.chatWindow?.onQuickChat?()
        XCTAssertTrue(bar.chatWindow?.isPresentationVisible == true); XCTAssertEqual(bar.chatPresentation?.activeMode, .full)
        await f.close()
    }
}
