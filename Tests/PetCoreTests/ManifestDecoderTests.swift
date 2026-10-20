import Foundation
import XCTest
@testable import PetCore

final class ManifestDecoderTests: XCTestCase {
    func testMinimalManifestDefaultsAndIdle() throws {
        let pet = try ManifestDecoder.decode(SkinFixtures.minimalManifest)
        XCTAssertEqual(pet.id, "my-pet")
        XCTAssertEqual(pet.spriteSheet, "spritesheet.png")
        XCTAssertEqual(pet.animations[.idle]?.durationsMs, [300, 200])
        XCTAssertEqual(pet.lookDirections.count, 0)
        XCTAssertNil(pet.speech)
    }
    func testEscapedDuplicateAndBooleanIntegerAreRejected() {
        XCTAssertThrowsError(try StrictJSON.validate(Data(#"{"id":"a","\u0069d":"b"}"#.utf8)))
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.replacing("\"schemaVersion\": 1", with: "\"schemaVersion\": true")))
    }
}

extension ManifestDecoderTests {
    func testThreeLegacyManifestCopies() throws {
        for name in ["ye-shunguang", "robin", "hutao"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "LegacyManifests"))
            XCTAssertFalse(try ManifestDecoder.decode(Data(contentsOf: url)).name.isEmpty)
        }
    }
    func testUnknownDuplicateAndInvalidSyntax() {
        for text in [#"{"a":1,"A":2}"#, #"{"x":{"a":1,"a":2}}"#, #"{"a":1,}"#, #"[1,]"#, #"{"a": /*x*/1}"#, #"{"a":1}{}"#] {
            XCTAssertThrowsError(try StrictJSON.validate(Data(text.utf8)), text)
        }
        for changes: [String: Any] in [["SchemaVersion":1], ["other":true], ["schemaVersion":true], ["schemaVersion":0], ["schemaVersion":2], ["id":"con"], ["id":"Upper"], ["id":"1abc"], ["id":""], ["name":"\n"], ["description":NSNull()], ["spriteSheet":"../x.png"], ["spriteSheet":"C:x.png"]] {
            XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(changes)), "\(changes)")
        }
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.replacing("\"schemaVersion\": 1", with: "\"schemaVersion\": 1.0")))
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.replacing("\"schemaVersion\": 1", with: "\"schemaVersion\": 1e0")))
    }
    func testAnimationAndImageLimits() throws {
        for ms in [20,10000] { _ = try ManifestDecoder.decode(SkinFixtures.manifest(["animations":["idle":["durationsMs":[ms],"loop":true]]])) }
        for ms in [19,10001] { XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(["animations":["idle":["durationsMs":[ms],"loop":true]]]))) }
        for animation: [String:Any] in [["durationsMs":[],"loop":true],["durationsMs":[100],"loop":false],["durationsMs":[100],"row":1,"loop":true],["durationsMs":[100,100],"startColumn":1,"loop":true]] {
            XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(["animations":["idle":animation]])))
        }
        for v in [16,512] { _ = try ManifestDecoder.decode(SkinFixtures.manifest(["cellWidth":v,"cellHeight":v])) }
        for change: [String:Any] in [["cellWidth":15],["cellHeight":513],["columns":0],["rows":65],["cellWidth":512,"columns":64],["cellWidth":512,"columns":16,"cellHeight":512,"rows":16]] { XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(change))) }
    }
    func testOptionalFieldsPreserveDefaultsAndNullRules() throws {
        let m = try ManifestDecoder.decode(SkinFixtures.manifest(["speech":NSNull(),"behavior":NSNull(),"lookDirections":[]]))
        XCTAssertNil(m.speech); XCTAssertNil(m.behavior)
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(["lookDirections":NSNull()])))
        let look = Array(repeating:["row":0,"column":0],count:16)
        XCTAssertEqual(try ManifestDecoder.decode(SkinFixtures.manifest(["lookDirections":look])).lookDirections.count,16)
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(["lookDirections":Array(look.dropLast())])))
        let speech = try ManifestDecoder.decode(SkinFixtures.manifest(["speech":["click":["我在。"]]]))
        XCTAssertEqual(speech.speech?.click,["我在。"])
        XCTAssertEqual(speech.speech?.drag,[])
    }
    func testSpeechUsesUTF16Length() throws {
        _ = try ManifestDecoder.decode(SkinFixtures.manifest(["speech":["click":[String(repeating:"😀",count:40)]]]))
        for line in [String(repeating:"😀",count:41),"\n","   "] { XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(["speech":["click":[line]]]))) }
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.manifest(["speech":["click":Array(repeating:"x",count:9)]])))
    }
    func testBehaviorLimitsAndReferences() throws {
        func data(_ rules: [[String:Any]], durations: [Int] = [100]) throws -> Data {
            try SkinFixtures.manifest(["columns":4,"animations":["idle":["durationsMs":[100],"loop":true],"waving":["durationsMs":durations]],"behavior":["rules":rules]])
        }
        for w in [1,100] { for c in [5,3600] { _ = try ManifestDecoder.decode(data([["weight":w,"cooldownSeconds":c]])) } }
        for rule: [String:Any] in [["weight":0],["weight":101],["cooldownSeconds":4],["cooldownSeconds":3601],["action":"idle"],["action":"failed"],["condition":"other"],["priority":1]] { XCTAssertThrowsError(try ManifestDecoder.decode(data([rule]))) }
        _ = try ManifestDecoder.decode(data([[:]],durations:[10000,10000,10000]))
        XCTAssertThrowsError(try ManifestDecoder.decode(data([[:]],durations:[10000,10000,10000,20])))
        XCTAssertThrowsError(try ManifestDecoder.decode(data([[:],[:]])))
        XCTAssertThrowsError(try ManifestDecoder.decode(data(Array(repeating:[:],count:10))))
        let actions = ["waving","jumping","failed"]
        let rules = ["any","cursorNear","cursorFar"].flatMap { c in actions.map { ["condition":c,"action":$0] } }
        _ = try ManifestDecoder.decode(SkinFixtures.manifest(["animations":["idle":["durationsMs":[100],"loop":true],"waving":["durationsMs":[100]],"jumping":["durationsMs":[100]],"failed":["durationsMs":[100]]],"behavior":["rules":rules]]))
    }
}
