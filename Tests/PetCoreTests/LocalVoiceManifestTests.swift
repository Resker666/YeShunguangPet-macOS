import Foundation
import XCTest
import PetCore

final class LocalVoiceManifestTests: XCTestCase {
    func testManifestRejectsDuplicateKeysAndBoolAsByteCount() throws {
        let data = try LocalVoiceFixtures.manifest(), text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try LocalVoiceManifest.decode(data).id, "hutao-pilot-e1")
        for replacement in ["true", "4.0", "4e0", "-1", "268435457"] {
            let bad = text.replacingOccurrences(of: "\"bytes\":4", with: "\"bytes\":" + replacement)
            XCTAssertNotEqual(bad, text)
            XCTAssertThrowsError(try LocalVoiceManifest.decode(Data(bad.utf8)))
        }
        let duplicate = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
        XCTAssertThrowsError(try LocalVoiceManifest.decode(Data(duplicate.utf8)))
    }
    func testFixedFilesAndIDRules() throws {
        for id in ["con", "../hutao", "HuTao", "a\n", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try LocalVoiceManifest.decode(LocalVoiceFixtures.manifest { $0["id"] = id }))
        }
        for file in ["../s2.pth", "/s2.pth", "s2.PTH", "https://example.test/s2.pth"] {
            XCTAssertThrowsError(try LocalVoiceManifest.decode(LocalVoiceFixtures.manifest { $0["model"] = ["file": file, "bytes": 4, "sha256": LocalVoiceFixtures.testSHA] }))
        }
        for change: ([String: Any]) -> [String: Any] in [
            { var x = $0; x["schemaVersion"] = 2; return x },
            { var x = $0; x["language"] = "en"; return x },
            { var x = $0; x["extra"] = true; return x },
            { var x = $0; x["promptText"] = "\0"; return x },
            { var x = $0; x["engineProfile"] = "unknown"; return x }
        ] { XCTAssertThrowsError(try LocalVoiceManifest.decode(LocalVoiceFixtures.manifest { $0 = change($0) })) }
    }
    func testBoundsBOMAndOptionalSuggestion() throws {
        let original = try LocalVoiceFixtures.manifest { $0.removeValue(forKey: "suggestedCharacterID"); $0["name"] = String(repeating: "😀", count: 40) }
        XCTAssertNil(try LocalVoiceManifest.decode(Data([239,187,191]) + original).suggestedCharacterID)
        let padded = original + Data(repeating: 32, count: 16384 - original.count)
        XCTAssertNoThrow(try LocalVoiceManifest.decode(padded))
        XCTAssertThrowsError(try LocalVoiceManifest.decode(padded + Data([32])))
        XCTAssertThrowsError(try LocalVoiceManifest.decode(LocalVoiceFixtures.manifest { $0["name"] = String(repeating: "😀", count: 41) }))
        XCTAssertThrowsError(try LocalVoiceManifest.decode(LocalVoiceFixtures.manifest { $0["promptText"] = String(repeating: "中", count: 401) }))
        XCTAssertThrowsError(try LocalVoiceManifest.decode(LocalVoiceFixtures.manifest { $0["model"] = ["file": "s2.pth", "bytes": 4, "sha256": String(repeating: "g", count: 64)] }))
    }
}
