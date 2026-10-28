import Foundation
import XCTest
import PetCore

@MainActor private final class LocalVoiceManagementFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence: ControlledChatPersistence, writes: ChatWriteQueue
    var character = ChatCharacter(id: "hutao", name: "胡桃", description: "角色", skinRevision: 0)
    var allowed = true, stopResult = true
    var stops = 0
    lazy var model = ChatLocalVoiceController(persistence: persistence, writes: writes, context: { [weak self] in self?.character }, canMutate: { [weak self] in self?.allowed == true }, stopOutput: { [weak self] in self?.stops += 1; return self?.stopResult == true })
    init() throws {
        persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json")); writes = ChatWriteQueue(persistence: persistence)
        _ = try LocalVoiceServiceFixtures.configuration(root: root)
    }
    func importVoice() async throws -> UUID {
        try await chatEventually { model.isLoaded }
        model.preview(folder: try LocalVoiceFixtures.folder(root))
        try await chatEventually { model.preview != nil }
        model.confirmImport(); await model.waitForPendingMutations(); await writes.waitForPending()
        return try XCTUnwrap(model.index.packages.first?.id)
    }
    func close() async {
        model.dispose(); await persistence.releaseAllLoads(); await persistence.releaseWrite()
        await model.waitForPendingMutations(); await writes.waitForPending()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor final class ChatLocalVoiceControllerTests: XCTestCase {
    func testImportConfirmDoesNotBindEnableOrSpeak() async throws {
        let f = try LocalVoiceManagementFixture()
        _ = try await f.importVoice()
        XCTAssertTrue(f.model.index.bindings.isEmpty)
        XCTAssertEqual(f.model.entries.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("AI/voice.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("AI/characters/hutao.json").path))
        let selection = await f.model.resolve(for: f.character)
        XCTAssertEqual(selection, .system)
        await f.close()
    }
    func testBindingCommitsBeforeOutputSelectionChanges() async throws {
        let f = try LocalVoiceManagementFixture(), id = try await f.importVoice()
        let count = await f.persistence.operations.count
        await f.persistence.holdNextWrite()
        f.model.applyBinding(id, expected: f.character)
        await f.persistence.waitForOperations(count + 1)
        XCTAssertNil(f.model.index.binding(for: f.character.id))
        let beforeCommit = await f.model.resolve(for: f.character)
        XCTAssertEqual(beforeCommit, .system)
        await f.persistence.releaseWrite(); await f.model.waitForPendingMutations()
        XCTAssertEqual(f.model.index.binding(for: f.character.id), id)
        if case .local(let voice) = await f.model.resolve(for: f.character) { XCTAssertEqual(voice.libraryUUID, id) } else { XCTFail("missing local selection") }
        f.model.delete(id); XCTAssertNotNil(f.model.error)
        XCTAssertEqual(f.model.index.packages.count, 1)
        await f.close()
    }
    func testLateIndexLoadAndSameIDRevisionCannotApplyToWrongRole() async throws {
        let f = try LocalVoiceManagementFixture()
        await f.persistence.holdNextLoad("localVoice")
        let model = f.model, old = f.character
        let resolving = Task { await model.resolve(for: old) }
        await f.persistence.waitForLoad("localVoice")
        f.character = .init(id: old.id, name: old.name, description: old.description, skinRevision: 1)
        await f.persistence.releaseLoad("localVoice")
        if case .unavailable = await resolving.value {} else { XCTFail("stale role must not resolve") }
        model.applyBinding(nil, expected: old)
        XCTAssertTrue(model.index.bindings.isEmpty)
        let operations = await f.persistence.operations; XCTAssertTrue(operations.isEmpty)
        await f.close()
    }
    func testCloseAfterAcceptedImportKeepsFIFOTransaction() async throws {
        let f = try LocalVoiceManagementFixture()
        try await chatEventually { f.model.isLoaded }
        let source = try LocalVoiceFixtures.folder(f.root)
        f.model.preview(folder: source); try await chatEventually { f.model.preview != nil }
        await f.persistence.holdNextWrite()
        f.model.confirmImport(); await f.persistence.waitForOperations(1)
        f.model.cancelPreview(); f.model.dispose()
        try FileManager.default.removeItem(at: source)
        await f.persistence.releaseWrite(); await f.model.waitForPendingMutations()
        let worker = ChatArchiveWorker(settingsURL: f.root.appendingPathComponent("settings.json"))
        if case .loaded(let index) = await worker.loadLocalVoiceIndex() { XCTAssertEqual(index.packages.count, 1) } else { XCTFail("accepted write lost") }
        await f.close()
    }
    func testFailedSaveAndCleanupRemainRetryableAtExit() async throws {
        let f = try LocalVoiceManagementFixture()
        try await chatEventually { f.model.isLoaded }
        let source = try LocalVoiceFixtures.folder(f.root)
        f.model.preview(folder: source); try await chatEventually { f.model.preview != nil }
        await f.persistence.failNext("localVoice")
        f.model.confirmImport(); await f.model.waitForPendingMutations()
        XCTAssertNotNil(f.model.terminationError)
        try FileManager.default.removeItem(at: source)
        f.model.beginTermination(); f.model.retryPendingForTermination(); await f.model.waitForPendingMutations()
        XCTAssertNil(f.model.terminationError); XCTAssertEqual(f.model.index.packages.count, 1)
        await f.close()

        let cleanup = try LocalVoiceManagementFixture()
        try await chatEventually { cleanup.model.isLoaded }
        cleanup.model.preview(folder: try LocalVoiceFixtures.folder(cleanup.root))
        try await chatEventually { cleanup.model.preview != nil }
        let stage = try XCTUnwrap(cleanup.model.preview)
        await cleanup.persistence.failNextLocalVoiceDiscard()
        cleanup.model.cancelPreview(); await cleanup.model.waitForPendingMutations()
        XCTAssertNotNil(cleanup.model.terminationError)
        cleanup.model.beginTermination(); cleanup.model.retryPendingForTermination(); await cleanup.model.waitForPendingMutations()
        XCTAssertNil(cleanup.model.terminationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.privateDirectory.path))
        await cleanup.close()
    }
    func testRepeatedImportReusesContentAndStoppedOutputFailureCannotBind() async throws {
        let f = try LocalVoiceManagementFixture(), id = try await f.importVoice()
        f.model.preview(folder: try LocalVoiceFixtures.folder(f.root)); try await chatEventually { f.model.preview != nil }
        f.model.confirmImport(); await f.model.waitForPendingMutations()
        XCTAssertEqual(f.model.index.packages.map(\.id), [id])
        f.stopResult = false
        f.model.applyBinding(id, expected: f.character); await f.model.waitForPendingMutations()
        XCTAssertNil(f.model.index.binding(for: f.character.id)); XCTAssertNotNil(f.model.error)
        await f.close()
    }
    func testConflictingPackageIDStaysAnUnconfirmedCancelablePreview() async throws {
        let f = try LocalVoiceManagementFixture()
        _ = try await f.importVoice()
        let source = try LocalVoiceFixtures.folder(f.root)
        try LocalVoiceFixtures.manifest { $0["name"] = "相同 ID 的另一份音色" }.write(to: source.appendingPathComponent("voice.json"))
        f.model.preview(folder: source); try await chatEventually { f.model.preview != nil }
        let staged = try XCTUnwrap(f.model.preview)
        f.model.confirmImport(); await f.model.waitForPendingMutations()
        XCTAssertNotNil(f.model.preview)
        XCTAssertFalse(f.model.hasUnsaved)
        XCTAssertNotNil(f.model.error)
        f.model.cancelPreview(); await f.model.waitForPendingMutations()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.privateDirectory.path))
        XCTAssertEqual(f.model.index.packages.count, 1)
        await f.close()
    }
    func testProtectedIndexReturnsReasonAndResetPreservesOriginalBytes() async throws {
        let f = try LocalVoiceManagementFixture()
        let url = f.root.appendingPathComponent("LocalVoice/index.json"), invalid = Data("broken index".utf8)
        try invalid.write(to: url)
        try await chatEventually { f.model.isLoaded }
        XCTAssertNotNil(f.model.protection)
        let selection = await f.model.resolve(for: f.character)
        XCTAssertEqual(selection, .unavailable(.libraryProtected))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        f.model.backupAndReset(); await f.model.waitForPendingMutations()
        XCTAssertNil(f.model.protection)
        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("index.json.backup-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), invalid)
        await f.close()
    }
    func testUnconfirmedPreviewRejectsOtherLibraryMutations() async throws {
        let f = try LocalVoiceManagementFixture(), id = try await f.importVoice()
        f.model.preview(folder: try LocalVoiceFixtures.folder(f.root, id: "other"))
        try await chatEventually { f.model.preview != nil }
        let before = await f.persistence.operations.count
        f.model.applyBinding(id, expected: f.character)
        await f.model.waitForPendingMutations()
        let after = await f.persistence.operations.count
        XCTAssertEqual(after, before)
        XCTAssertNil(f.model.index.binding(for: f.character.id))
        f.model.cancelPreview(); await f.model.waitForPendingMutations()
        await f.close()
    }
    func testReadDuringHeldInitialLibraryLoadWaitsInsteadOfBeingRejected() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        await f.persistence.holdNextLoad("localVoice")
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
        f.controller.configureVoice(services: .init(input: input, output: output), now: { .zero })
        let voice = try XCTUnwrap(f.controller.voice)
        await f.persistence.waitForLoad("localVoice")
        try await chatEventually { voice.settings.isLoaded }
        voice.settings.apply(.init(enabled: true)); await f.controller.waitForPendingWrites()
        f.controller.updateVoiceEnvironment(.init(surface: .conversation))
        voice.readLatest("载入期间的新朗读")
        XCTAssertTrue(voice.hasOutputActivity)
        XCTAssertNil(voice.error); XCTAssertTrue(output.spoken.isEmpty)
        await f.persistence.releaseLoad("localVoice")
        try await chatEventually { output.spoken.count == 1 }
        await f.close()
    }
}
