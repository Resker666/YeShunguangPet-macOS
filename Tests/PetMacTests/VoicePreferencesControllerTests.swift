import Foundation
import XCTest
import PetCore

@MainActor final class VoicePreferencesControllerTests: XCTestCase {
    private func fixture() throws -> (URL, ControlledChatPersistence, ChatWriteQueue, ChatVoicePreferencesController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-settings-" + UUID().uuidString)
        let persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json"))
        let queue = ChatWriteQueue(persistence: persistence)
        let controller = ChatVoicePreferencesController(persistence: persistence, writes: queue)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, persistence, queue, controller)
    }
    func testDisableSurvivesLateEnableReceiptAndFailedSave() async throws {
        let (_, persistence, queue, controller) = try fixture()
        try await chatEventually { controller.isLoaded }
        await persistence.holdNextWrite(); await persistence.failOperation(at: 2)
        controller.apply(.init(enabled: true))
        await persistence.waitForOperations(1)
        var disabled = 0; controller.onDisable = { disabled += 1 }
        controller.disable()
        XCTAssertFalse(controller.enabledForSession); XCTAssertEqual(disabled, 1)
        await persistence.releaseWrite(); await queue.waitForPending()
        XCTAssertFalse(controller.enabledForSession); XCTAssertTrue(controller.hasUnsaved)
        XCTAssertNotNil(controller.error)
        controller.retryPendingSave(); await queue.waitForPending()
        XCTAssertFalse(controller.enabledForSession); XCTAssertFalse(controller.hasUnsaved)
        controller.apply(.init(enabled: true)); await queue.waitForPending()
        XCTAssertTrue(controller.enabledForSession)
        controller.dispose()
    }
    func testRetryEnabledCandidateCannotClearTemporaryDisable() async throws {
        let (_, persistence, queue, controller) = try fixture()
        try await chatEventually { controller.isLoaded }
        await persistence.failNext("voicePreferences")
        controller.apply(.init(enabled: true)); await queue.waitForPending()
        XCTAssertTrue(controller.hasUnsaved)
        controller.disable(); await queue.waitForPending()
        await persistence.failNext("voicePreferences")
        controller.apply(.init(enabled: true)); await queue.waitForPending()
        controller.retryPendingSave(); await queue.waitForPending()
        XCTAssertTrue(controller.preferences.enabled)
        XCTAssertFalse(controller.enabledForSession)
        controller.dispose()
    }
    func testVoiceFIFOIsSharedWithAcceptedChatWrites() async throws {
        let (root, persistence, queue, controller) = try fixture()
        try await chatEventually { controller.isLoaded }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("AI/voice.json").path))
        await persistence.holdNextWrite()
        queue.enqueue(.append(characterID: "robin", user: "问", assistant: "答")) { _, result in if case .failure = result { XCTFail("append") } }
        await persistence.waitForOperations(1)
        controller.apply(.init(enabled: true))
        queue.enqueue(.clear(characterID: "robin")) { _, result in if case .failure = result { XCTFail("clear") } }
        controller.dispose()
        await persistence.releaseWrite(); await queue.waitForPending()
        let operations = await persistence.operations
        XCTAssertEqual(operations, ["append:robin", "voicePreferences", "clear:robin"])
        guard case .loaded(let voice) = VoicePreferencesStore(url: root.appendingPathComponent("AI/voice.json")).load(), case .loaded(let chat) = ChatStore(directory: root.appendingPathComponent("AI/characters")).load(characterID: "robin") else { return XCTFail("missing") }
        XCTAssertTrue(voice.enabled); XCTAssertTrue(chat.messages.isEmpty)
    }
    func testProtectedResetIsLocalAndFailureRetainsProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let voiceURL = root.appendingPathComponent("AI/voice.json")
        try FileManager.default.createDirectory(at: voiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad voice".utf8).write(to: voiceURL)
        let connectionURL = root.appendingPathComponent("AI/connection.json")
        try ChatConnectionStore(url: connectionURL).save(.init(enabled: true)); let before = try Data(contentsOf: connectionURL)
        let persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json")), queue = ChatWriteQueue(persistence: persistence)
        let controller = ChatVoicePreferencesController(persistence: persistence, writes: queue)
        try await chatEventually { controller.isLoaded }
        XCTAssertNotNil(controller.protection); XCTAssertFalse(controller.enabledForSession)
        await persistence.failNext("resetVoicePreferences"); controller.backupAndReset(); await queue.waitForPending()
        XCTAssertNotNil(controller.protection); XCTAssertEqual(try Data(contentsOf: voiceURL), Data("bad voice".utf8))
        controller.backupAndReset(); await queue.waitForPending()
        XCTAssertNil(controller.protection); XCTAssertFalse(controller.enabledForSession)
        XCTAssertEqual(try Data(contentsOf: connectionURL), before)
        controller.dispose()
    }
    func testApplyingDisabledPreferencesKeepsChosenVoiceAndRate() async throws {
        let (_, _, queue, controller) = try fixture()
        try await chatEventually { controller.isLoaded }
        let requested = VoicePreferences(enabled: false, automaticReadAloud: false, voiceIdentifier: "chosen", rate: 0.6)
        controller.apply(requested); await queue.waitForPending()
        XCTAssertEqual(controller.preferences, requested)
        XCTAssertFalse(controller.enabledForSession)
        controller.dispose()
    }
    func testDisposeRejectsLateLoadAndNewCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json")), queue = ChatWriteQueue(persistence: persistence)
        await persistence.holdNextLoad("voice")
        let controller = ChatVoicePreferencesController(persistence: persistence, writes: queue)
        await persistence.waitForLoad("voice"); controller.dispose(); await persistence.releaseLoad("voice")
        controller.apply(.init(enabled: true)); controller.disable(); controller.backupAndReset()
        await queue.waitForPending()
        let operations = await persistence.operations; XCTAssertTrue(operations.isEmpty)
        XCTAssertFalse(controller.isLoaded); XCTAssertFalse(controller.enabledForSession)
    }
}
