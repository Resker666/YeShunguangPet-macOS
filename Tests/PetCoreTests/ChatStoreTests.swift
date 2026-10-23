import Foundation
import CryptoKit
import XCTest
import PetCore

final class ChatStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ directory: URL, id: String = "robin") -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private func loaded<T>(_ result: ChatLoadResult<T>) throws -> T {
        guard case .loaded(let value) = result else { throw NSError(domain: "ExpectedLoadedChat", code: 1) }
        return value
    }
    private func put(_ bytes: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    private let valid = Data(#"{"schemaVersion":1,"conversation":{"characterID":"robin","profile":{"background":"","personality":"","speakingStyle":"","examples":""},"messages":[]}}"#.utf8)

    func testV1LoadsWithoutRewriteAndWritesV2OnMutation() throws {
        let directory = try root().appendingPathComponent("AI/characters")
        let messages = (1...12).flatMap { number in [["role": "user", "content": "问\(number)"], ["role": "assistant", "content": "答\(number)"]] }
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "conversation": ["characterID": "robin", "profile": ["background": "旧人设", "personality": "", "speakingStyle": "", "examples": ""], "messages": messages]])
        try put(bytes, at: file(directory))
        let store = ChatStore(directory: directory)
        let state = try loaded(store.load(characterID: "robin"))
        XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
        XCTAssertEqual(state.profile.background, "旧人设")
        XCTAssertEqual(state.messages.map(\.content), messages.map { $0["content"]! })
        XCTAssertEqual(state.memories, [])
        XCTAssertEqual(state.memoryRevision, 0)
        try store.save(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file(directory))) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(try loaded(ChatStore(directory: directory).load(characterID: "robin")), state)
    }

    func testV2MissingInvalidMemoryFieldsRemainProtected() throws {
        let directory = try root().appendingPathComponent("AI/characters")
        let state = try ChatConversation(characterID: "robin", memories: [ChatMemory(text: "é")])
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var cases = [[String: Any]]()
        for field in ["memories", "memoryRevision"] {
            var missing = base; missing.removeValue(forKey: field); cases.append(missing)
            var null = base; null[field] = NSNull(); cases.append(null)
        }
        for bad: Any in [-1, 1.5, "0", true] { var value = base; value["memoryRevision"] = bad; cases.append(value) }
        let id = UUID().uuidString
        for memories: Any in ["bad", [["id": id, "text": "a"], ["id": id, "text": "b"]], [["id": id, "text": "é"], ["id": UUID().uuidString, "text": "e\u{301}"]], [["id": id, "text": " untrimmed "]]] {
            var value = base; value["memories"] = memories; cases.append(value)
        }
        for value in cases {
            let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "conversation": value])
            try put(bytes, at: file(directory))
            let store = ChatStore(directory: directory)
            if case .protectedFile = store.load(characterID: "robin") {} else { XCTFail("invalid v2 accepted") }
            XCTAssertThrowsError(try store.save(state))
            XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
        }
    }

    func testResetBacksUpAllCharacterData() throws {
        let directory = try root().appendingPathComponent("AI/characters")
        let store = ChatStore(directory: directory)
        let prior = try ChatConversation(characterID: "robin", profile: .init(background: "旧背景"), memories: [ChatMemory(text: "旧记忆")], memoryRevision: 5).appending(user: "问", assistant: "答")
        try store.save(prior)
        let original = try Data(contentsOf: file(directory))
        let bad = ChatStore(directory: directory, backup: { _, _ in throw SkinError("injected") })
        XCTAssertThrowsError(try bad.backupAndReset(characterID: "robin", profile: .init()))
        XCTAssertEqual(try Data(contentsOf: file(directory)), original)
        let fresh = try store.backupAndReset(characterID: "robin", profile: .init())
        XCTAssertEqual(fresh.profile, ChatProfile())
        XCTAssertTrue(fresh.messages.isEmpty && fresh.memories.isEmpty)
        XCTAssertEqual(fresh.memoryRevision, 0)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(try files.filter { $0 != file(directory) }.contains { try Data(contentsOf: $0) == original })
    }

    func testArchivesReopenAndPreserveMainSettings() throws {
        let base = try root(), directory = base.appendingPathComponent("AI/characters")
        let settings = base.appendingPathComponent("settings.json"), original = Data("PRIVATE-MAIN-CONFIG".utf8)
        try original.write(to: settings)
        let store = ChatStore(directory: directory)
        if case .missing = store.load(characterID: "robin") {} else { XCTFail("missing archive did not stay missing") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var state = try ChatConversation(characterID: "robin", profile: .init(background: "会记住的人设"))
        for i in 1...12 { state = try state.appending(user: "问\(i)", assistant: "答\(i)") }
        try store.save(state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(directory).path))
        XCTAssertEqual(try loaded(ChatStore(directory: directory).load(characterID: "robin")), state)
        if case .missing = store.load(characterID: "hutao") {} else { XCTFail("different character shared an archive") }
        let connectionURL = base.appendingPathComponent("AI/connection.json")
        let connection = ChatConnectionStore(url: connectionURL)
        try connection.save(.init(enabled: true, model: .pro))
        XCTAssertEqual(try loaded(ChatConnectionStore(url: connectionURL).load()), .init(enabled: true, model: .pro))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: connectionURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: connectionURL), as: UTF8.self).contains("key"))
    }

    func testLargeChineseArchiveRetainsSkinLimit() throws {
        let directory = try root().appendingPathComponent("AI/characters")
        var state = try ChatConversation(characterID: "robin")
        for _ in 1...12 { state = try state.appending(user: String(repeating: "问", count: 2000), assistant: String(repeating: "答", count: 8000)) }
        try ChatStore(directory: directory).save(state)
        let bytes = try Data(contentsOf: file(directory))
        XCTAssertGreaterThan(bytes.count, 131072)
        XCTAssertLessThan(bytes.count, 2097152)
        XCTAssertThrowsError(try StrictJSON.validate(bytes))
        XCTAssertEqual(try loaded(ChatStore(directory: directory).load(characterID: "robin")).messages.count, 24)
    }

    func testProtectedArchivesNeverOverwrite() throws {
        let directory = try root().appendingPathComponent("AI/characters")
        let cases = [
            Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":9"#).utf8),
            Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":1,"schemaVersion":1"#).utf8),
            Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: #""characterID":"robin""#, with: #""characterID":"hutao""#).utf8),
            Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: #""messages":[]"#, with: #""messages":[{"role":"user","content":"半轮"}]"#).utf8),
            Data(repeating: 32, count: 2097153)
        ]
        for bytes in cases {
            try put(bytes, at: file(directory))
            let store = ChatStore(directory: directory)
            if case .protectedFile = store.load(characterID: "robin") {} else { XCTFail("bad character archive accepted") }
            XCTAssertThrowsError(try store.save(ChatConversation(characterID: "robin")))
            XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
        }
        let url = directory.deletingLastPathComponent().appendingPathComponent("connection.json")
        for bytes in [Data(repeating: 32, count: 8193), Data(#"{"schemaVersion":1,"connection":{"enabled":true,"model":"unknown"}}"#.utf8)] {
            try put(bytes, at: url)
            let store = ChatConnectionStore(url: url)
            if case .protectedFile = store.load() {} else { XCTFail("bad connection accepted") }
            XCTAssertThrowsError(try store.save(.init()))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testAtomicWriteAndResetFailures() throws {
        let base = try root(), directory = base.appendingPathComponent("AI/characters")
        let store = ChatStore(directory: directory)
        try store.save(ChatConversation(characterID: "robin", profile: .init(background: "SECRET-PERSONA")))
        let original = try Data(contentsOf: file(directory))
        let failure = NSError(domain: "ChatInjectedWrite", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET-PERSONA"])
        let failing = ChatStore(directory: directory, write: { _, _ in throw failure })
        XCTAssertThrowsError(try failing.save(ChatConversation(characterID: "robin"))) { error in
            XCTAssertFalse(error.localizedDescription.contains("SECRET-PERSONA"))
        }
        XCTAssertEqual(try Data(contentsOf: file(directory)), original)
        let bad = Data("broken".utf8)
        try bad.write(to: file(directory))
        let backupFailure = ChatStore(directory: directory, backup: { _, _ in throw failure })
        XCTAssertThrowsError(try backupFailure.backupAndReset(characterID: "robin", profile: .init()))
        XCTAssertThrowsError(try backupFailure.save(ChatConversation(characterID: "robin")))
        XCTAssertEqual(try Data(contentsOf: file(directory)), bad)
        let resetWriteFailure = ChatStore(directory: directory, write: { _, _ in throw failure })
        XCTAssertThrowsError(try resetWriteFailure.backupAndReset(characterID: "robin", profile: .init()))
        XCTAssertEqual(try Data(contentsOf: file(directory)), bad)
        let reset = try ChatStore(directory: directory).backupAndReset(characterID: "robin", profile: .init(background: "新起点"))
        XCTAssertEqual(reset.messages.count, 0)
        XCTAssertEqual(reset.profile.background, "新起点")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.pathExtension == "tmp" })
        XCTAssertTrue(try files.filter { $0 != file(directory) }.contains { try Data(contentsOf: $0) == bad })
        for (url, expected) in [(directory, 0o700), (file(directory), 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
    }
}
