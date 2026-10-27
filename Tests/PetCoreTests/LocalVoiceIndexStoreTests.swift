import Foundation
import XCTest
import PetCore

final class LocalVoiceIndexStoreTests: XCTestCase {
    func testIndexSaveFailurePreservesOldBindingAndRetryReusesStagedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice"))
        let good = LocalVoiceIndexStore(root: library.root)
        let first = try good.apply(.install(library.stage(folder: LocalVoiceFixtures.folder(root))))
        let id = try XCTUnwrap(first.installedID)
        _ = try good.apply(.bind(characterID: "hutao", libraryID: id))
        let original = try Data(contentsOf: library.root.appendingPathComponent("index.json"))
        var fail = true
        let store = LocalVoiceIndexStore(root: library.root, write: { data, url in
            if fail { throw LocalVoiceError("模拟写失败") }; try data.write(to: url, options: .atomic)
        })
        let source = try LocalVoiceFixtures.folder(root, id: "other"), stage = try library.stage(folder: source)
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try store.apply(.install(stage)))
        XCTAssertEqual(try Data(contentsOf: library.root.appendingPathComponent("index.json")), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.privateDirectory.path))
        fail = false
        let retry = try store.apply(.install(stage))
        XCTAssertEqual(retry.index.binding(for: "hutao"), id)
        XCTAssertEqual(retry.index.packages.count, 2)
    }
    func testCleanupFailureIsCommittedAndStaleCleanupCannotDeleteRegisteredVoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice"))
        let store = LocalVoiceIndexStore(root: library.root, remove: { _ in throw LocalVoiceError("模拟清理失败") })
        let commit = try store.apply(.install(library.stage(folder: LocalVoiceFixtures.folder(root))))
        XCTAssertEqual(commit.cleanupPending.count, 1)
        let id = try XCTUnwrap(commit.installedID)
        let retry = try store.apply(.retryCleanup([.init(namespace: .unregisteredVoice, id: id)]))
        XCTAssertEqual(retry.index.packages.count, 1)
        XCTAssertNoThrow(try library.resolve(libraryID: id, index: retry.index))
        let removed = try store.apply(.remove(id))
        XCTAssertTrue(removed.index.packages.isEmpty)
        XCTAssertEqual(removed.cleanupPending, [.init(namespace: .unregisteredVoice, id: id)])
    }
    func testMissingDoesNotCreateAndBadIndexProtectedUntilBackupReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalVoiceIndexStore(root: root)
        if case .missing = store.load() {} else { XCTFail("expected missing") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = Data(repeating: 32, count: 65537), url = root.appendingPathComponent("index.json")
        try invalid.write(to: url)
        let protected = LocalVoiceIndexStore(root: root)
        if case .protectedFile = protected.load() {} else { XCTFail("expected protected") }
        XCTAssertThrowsError(try protected.apply(.bind(characterID: "hutao", libraryID: nil)))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        XCTAssertTrue(try protected.apply(.reset).index.packages.isEmpty)
        let backup = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("index.json.backup-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), invalid)
    }
}
