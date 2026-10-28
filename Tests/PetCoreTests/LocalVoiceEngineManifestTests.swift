import Foundation
import XCTest
import PetCore

final class LocalVoiceEngineManifestTests: XCTestCase {
    func testStrictManifestAndFixedContract() throws {
        let value = try LocalVoiceEngineManifest.decode(LocalVoiceEngineFixtures.manifest())
        XCTAssertEqual(value.id, "portable-test"); XCTAssertEqual(value.files.count, 5)
        XCTAssertEqual(value.files.first { $0.path == "source/__init__.py" }?.bytes, 0)
        let invalid: [(String, Any)] = [("schemaVersion", 2), ("architecture", "x86_64"), ("minimumOS", "27.0"), ("pythonVersion", "3.13.0"), ("sourceCommit", String(repeating: "0", count: 40)), ("version", "v1.0.0"), ("command", "install.sh")]
        for (key, bad) in invalid { XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(LocalVoiceEngineFixtures.manifest { $0[key] = bad }), key) }
        let original = try LocalVoiceEngineFixtures.manifest()
        let duplicate = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(Data(duplicate.utf8)))
        for bad: Any in [1, "true", NSNull()] {
            XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(LocalVoiceEngineFixtures.manifest {
                var files = $0["files"] as! [[String: Any]]; files[0]["executable"] = bad; $0["files"] = files
            }))
        }
    }
    private func adding(_ extra: [[String: Any]]) throws -> Data {
        try LocalVoiceEngineFixtures.manifest { $0["files"] = ($0["files"] as! [[String: Any]]) + extra }
    }
    private func entry(_ path: String, bytes: UInt64 = 0) -> [String: Any] { ["path": path, "bytes": bytes, "sha256": LocalVoiceEngineFixtures.emptySHA, "executable": false] }
    func testLimitsAndNormalizedPathCollisions() throws {
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(Data(repeating: 32, count: 16 * 1024 * 1024 + 1)))
        for path in ["../out", "/absolute", "source//a", "source/./a", "source/../a", "source\\a", Array(repeating: "a", count: 33).joined(separator: "/")] {
            XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(adding([entry(path)])), path)
        }
        for pair in [[entry("source/A"), entry("source/a")], [entry("source/Café"), entry("source/Cafe\u{301}")], [entry("source/file"), entry("source/file/child")]] {
            XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(adding(pair)))
        }
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(adding([entry("source/huge", bytes: 2 * 1024 * 1024 * 1024 + 1)])))
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(adding([entry("source/overflow", bytes: UInt64.max)])))
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(adding((0..<7).map { entry("source/big\($0)", bytes: 2 * 1024 * 1024 * 1024) })))
    }
    func testRecordLimitAndRequiredSubtrees() throws {
        let tooMany = try LocalVoiceEngineFixtures.manifest { $0["files"] = (0..<100001).map { entry("f\($0)") } }
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(tooMany))
        for prefix in ["runtime/", "source/", "licenses/", "engine-assets.json"] {
            XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(LocalVoiceEngineFixtures.manifest {
                $0["files"] = ($0["files"] as! [[String: Any]]).filter { !($0["path"] as! String).hasPrefix(prefix) }
            }))
        }
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(LocalVoiceEngineFixtures.manifest {
            var files = $0["files"] as! [[String: Any]]
            let n = files.firstIndex { $0["path"] as? String == "runtime/bin/python3.12" }!
            files[n]["bytes"] = 0; files[n]["sha256"] = LocalVoiceEngineFixtures.emptySHA; $0["files"] = files
        }))
    }
    func testEmptyFileMustHaveEmptyDigestAndPayloadRootsAreFixed() throws {
        XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(LocalVoiceEngineFixtures.manifest {
            var files = $0["files"] as! [[String: Any]]
            let index = files.firstIndex { $0["path"] as? String == "source/__init__.py" }!
            files[index]["sha256"] = String(repeating: "0", count: 64); $0["files"] = files
        }))
        for path in ["install.py", "other/config.json"] {
            XCTAssertThrowsError(try LocalVoiceEngineManifest.decode(adding([entry(path)])))
        }
    }
}
