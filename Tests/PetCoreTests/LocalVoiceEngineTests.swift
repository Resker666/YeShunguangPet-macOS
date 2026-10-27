import Foundation
import XCTest
import PetCore

final class LocalVoiceEngineTests: XCTestCase {
    func testMissingEngineIsReadOnlyAndPathsAreFixedInsideVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(LocalVoiceEngineDescriptor.status(dataRoot: root), .unconfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let id = UUID(), base = root.appendingPathComponent("LocalVoice/Engine/Versions/" + id.uuidString)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("source"), withIntermediateDirectories: true)
        let python = base.appendingPathComponent("venv/bin/python")
        try Data("fake".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data("{\"files\":[]}".utf8).write(to: base.appendingPathComponent("engine-assets.json"))
        let url = root.appendingPathComponent("LocalVoice/Engine/current.json")
        var object: [String: Any] = ["schemaVersion": 1, "versionID": id.uuidString, "profile": LocalVoiceManifest.profile, "architecture": "arm64", "pythonVersion": "3.12", "sourceCommit": "b4570b876f5c086819ba84e3215472733c6a7b70", "python": "venv/bin/python", "source": "source", "assets": "engine-assets.json"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let descriptor = try LocalVoiceEngineDescriptor.load(dataRoot: root)
        XCTAssertEqual(try descriptor.resolve(dataRoot: root).pythonURL.standardizedFileURL, python.standardizedFileURL)
        for value in ["../python", "/usr/bin/python3", "source/../../python"] {
            object["python"] = value
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try LocalVoiceEngineDescriptor.load(dataRoot: root))
        }
        object["python"] = "venv/bin/python"
        object["extra"] = "ignored?"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try LocalVoiceEngineDescriptor.load(dataRoot: root))
        object.removeValue(forKey: "extra")
        let valid = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let duplicate = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
        try Data(duplicate.utf8).write(to: url)
        XCTAssertThrowsError(try LocalVoiceEngineDescriptor.load(dataRoot: root))
        if case .unavailable = LocalVoiceEngineDescriptor.status(dataRoot: root) {} else { XCTFail("corrupt descriptor must be unavailable") }
    }
}
