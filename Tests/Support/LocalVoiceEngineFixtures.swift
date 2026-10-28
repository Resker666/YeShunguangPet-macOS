import Foundation
import CryptoKit

enum LocalVoiceEngineFixtures {
    static let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let contents: [String: Data] = ["runtime/bin/python3.12": Data("#!/bin/sh\n/usr/bin/touch \"${0%/*}/preview-ran\"\nexit 99\n".utf8), "source/module.py": Data("SOURCE = True\n".utf8), "source/__init__.py": Data(), "licenses/LICENSE": Data("test license\n".utf8), "engine-assets.json": Data("{\"files\":[]}".utf8)]
    static func object() -> [String: Any] {
        let files: [[String: Any]] = contents.sorted { $0.key < $1.key }.map { path, data in
            ["path": path, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "executable": path == "runtime/bin/python3.12"]
        }
        return ["schemaVersion": 1, "id": "portable-test", "version": "1.0.0", "name": "测试引擎", "architecture": "arm64", "minimumOS": "14.0", "pythonVersion": "3.12.14", "profile": "gpt-sovits-v2proplus-cpu1", "sourceCommit": "b4570b876f5c086819ba84e3215472733c6a7b70", "files": files]
    }
    static func manifest(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = object(); change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func folder(_ parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in contents {
            let file = folder.appendingPathComponent("payload/" + path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            if path == "runtime/bin/python3.12" { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        }
        try manifest().write(to: folder.appendingPathComponent("engine.json"))
        return folder
    }
}
