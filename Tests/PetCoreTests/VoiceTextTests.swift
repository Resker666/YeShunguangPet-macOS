import Foundation
import XCTest
import PetCore

final class VoiceTextTests: XCTestCase {
    func testInsertionClampsToWholeGraphemesAndKeepsSurroundingDraft() throws {
        let value = try VoiceText.inserting("你好", into: "a😀b", replacing: .init(location: 2, length: 0))
        XCTAssertEqual(value.text, "a你好😀b")
        XCTAssertEqual(value.selection, .init(location: 3, length: 0))
        let replacement = try VoiceText.inserting("新", into: "a👨‍👩‍👧‍👦b", replacing: .init(location: 2, length: 1))
        XCTAssertEqual(replacement.text, "a新b")
        XCTAssertEqual(replacement.selection, .init(location: 2, length: 0))
        XCTAssertEqual(try VoiceText.inserting("末", into: "旧", replacing: .init(location: NSNotFound, length: 0)).text, "旧末")
        XCTAssertEqual(try VoiceText.inserting("末", into: "旧", replacing: .init(location: 999, length: 999)).text, "旧末")
        XCTAssertEqual(try VoiceText.inserting("新", into: "e\u{301}z", replacing: .init(location: 1, length: 1)).text, "新z")
    }

    func testInsertionRejectsEmptyControlsAndOversizedResultWithoutTruncating() throws {
        XCTAssertThrowsError(try VoiceText.inserting(" \n ", into: "旧", replacing: .init(location: 0, length: 0)))
        XCTAssertThrowsError(try VoiceText.inserting("\0", into: "旧", replacing: .init(location: 0, length: 0)))
        let full = String(repeating: "a", count: 2000)
        XCTAssertEqual(try VoiceText.inserting("字", into: full, replacing: .init(location: 1999, length: 1)).text.utf16.count, 2000)
        XCTAssertThrowsError(try VoiceText.inserting("字", into: full, replacing: .init(location: 2000, length: 0)))
    }

    func testAutomaticReadUsesBoundedWholeGraphemesAndNearbySentenceEnd() {
        let emoji = VoiceText.automaticExcerpt(String(repeating: "😀", count: 400))
        XCTAssertLessThanOrEqual(emoji.utf16.count, 600)
        XCTAssertTrue(emoji.allSatisfy { $0 == "😀" })
        XCTAssertEqual(VoiceText.automaticExcerpt("简短回复。"), "简短回复。")
        let sentence = String(repeating: "甲", count: 500) + "。"
        XCTAssertEqual(VoiceText.automaticExcerpt(sentence + String(repeating: "乙", count: 200)), sentence)
        let cluster = "👨‍👩‍👧‍👦"
        XCTAssertTrue(VoiceText.automaticExcerpt(String(repeating: cluster, count: 80)).allSatisfy { String($0) == cluster })
    }
}
