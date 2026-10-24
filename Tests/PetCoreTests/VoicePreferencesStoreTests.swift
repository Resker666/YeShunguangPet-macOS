import Foundation
import XCTest
import PetCore

final class VoicePreferencesStoreTests: XCTestCase {
    private func file() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-store-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("AI/voice.json")
    }
    private func loaded(_ result: ChatLoadResult<VoicePreferences>) throws -> VoicePreferences {
        guard case .loaded(let value) = result else { throw SkinError("expected loaded voice settings") }
        return value
    }

    func testMissingDoesNotCreateDirectoryAndSavedValuesReopen() throws {
        let url = file(), store = VoicePreferencesStore(url: file())
        if case .missing = store.load() {} else { XCTFail("missing must stay missing") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.deletingLastPathComponent().path))
        let value = VoicePreferences(enabled: true, automaticReadAloud: false, rate: 0.65)
        try VoicePreferencesStore(url: url).save(value)
        XCTAssertEqual(try loaded(VoicePreferencesStore(url: url).load()), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        XCTAssertTrue(preferences["voiceIdentifier"] is NSNull)
    }

    func testMalformedFilesRemainProtectedAndUnchanged() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let valid = #"{"schemaVersion":1,"preferences":{"enabled":true,"automaticReadAloud":true,"voiceIdentifier":null,"rate":0.5}}"#
        let variants = [
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            valid.replacingOccurrences(of: "\"enabled\":true", with: "\"enabled\":1"),
            valid.replacingOccurrences(of: "\"rate\":0.5", with: "\"rate\":true"),
            valid.replacingOccurrences(of: "\"rate\":0.5", with: "\"rate\":0.7"),
            valid.replacingOccurrences(of: "\"rate\":0.5", with: "\"rate\":0.5,\"unknown\":1"),
            valid.replacingOccurrences(of: "\"rate\":0.5", with: "\"rate\":0.5,\"rate\":0.5"),
            valid.replacingOccurrences(of: "\"voiceIdentifier\":null,", with: ""),
            valid.replacingOccurrences(of: "\"preferences\":", with: "\"unknown\":1,\"preferences\":"),
            String(repeating: " ", count: 8193)
        ]
        for source in variants {
            let original = Data(source.utf8)
            try original.write(to: url)
            let store = VoicePreferencesStore(url: url)
            if case .protectedFile = store.load() {} else { XCTFail("malformed voice file accepted") }
            XCTAssertThrowsError(try store.save(.init()))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testSaveAndResetFailuresPreserveOriginalAndResetOnlyVoiceFile() throws {
        let url = file(), store = VoicePreferencesStore(url: url)
        try store.save(.init(enabled: true, rate: 0.35))
        let original = try Data(contentsOf: url)
        let sibling = url.deletingLastPathComponent().appendingPathComponent("connection.json")
        try Data("UNCHANGED-CONNECTION".utf8).write(to: sibling)
        let failing = VoicePreferencesStore(url: url, write: { _, _ in throw SkinError("RAW-PRIVATE-ERROR") })
        XCTAssertThrowsError(try failing.save(.init())) { XCTAssertFalse($0.localizedDescription.contains("RAW-PRIVATE-ERROR")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try failing.backupAndReset())
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try store.backupAndReset(), .init())
        XCTAssertEqual(try Data(contentsOf: sibling), Data("UNCHANGED-CONNECTION".utf8))
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertTrue(try files.filter { $0.lastPathComponent.hasPrefix("voice.json.backup-") }.contains { try Data(contentsOf: $0) == original })
    }

    func testSymbolicLinkIsNotLoadedOrOverwritten() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = url.deletingLastPathComponent().appendingPathComponent("original.json")
        let bytes = Data("KEEP".utf8)
        try bytes.write(to: original)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
        let store = VoicePreferencesStore(url: url)
        if case .protectedFile = store.load() {} else { XCTFail("link accepted") }
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertThrowsError(try store.backupAndReset())
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
