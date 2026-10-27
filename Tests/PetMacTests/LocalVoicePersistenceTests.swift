import Foundation
import XCTest
import PetCore

@MainActor final class LocalVoicePersistenceTests: XCTestCase {
    func testFIFOImportBindAndAcceptedChatWriteSurviveClosure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json"))
        let queue = ChatWriteQueue(persistence: persistence)
        let stage = try await persistence.stageLocalVoice(folder: LocalVoiceFixtures.folder(root))
        await persistence.holdNextWrite()
        var imported: UUID?
        queue.enqueue(.localVoice(.install(stage))) { _, result in
            if case .success(.localVoice(let commit)) = result { imported = commit.installedID }
        }
        queue.enqueue(.append(characterID: "hutao", user: "测试", assistant: "回复")) { _, result in
            if case .failure(let error) = result { XCTFail("\(error)") }
        }
        await persistence.waitForOperations(1)
        await persistence.releaseWrite()
        await queue.waitForPending()
        let id = try XCTUnwrap(imported)
        queue.enqueue(.localVoice(.bind(characterID: "hutao", libraryID: id))) { _, result in
            if case .failure(let error) = result { XCTFail("\(error)") }
        }
        await queue.waitForPending()
        let operations = await persistence.operations
        XCTAssertEqual(operations, ["localVoice", "append:hutao", "localVoice"])
        let worker = ChatArchiveWorker(settingsURL: root.appendingPathComponent("settings.json"))
        if case .loaded(let index) = await worker.loadLocalVoiceIndex() { XCTAssertEqual(index.binding(for: "hutao"), id) } else { XCTFail("missing index") }
        if case .loaded(let conversation) = await worker.loadCharacter(id: "hutao", defaultProfile: .init()) { XCTAssertEqual(conversation.messages.count, 2) } else { XCTFail("missing conversation") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("AI/voice.json").path))
    }
}
