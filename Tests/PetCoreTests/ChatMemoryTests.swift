import Foundation
import XCTest
import PetCore

final class ChatMemoryTests: XCTestCase {
    private func snapshot(memories: [ChatMemory] = []) throws -> MemoryExtractionSnapshot {
        let value = try ChatConversation(characterID: "robin", profile: .init(background: "PERSONA-NOT-EXTRACTION"), memories: memories)
            .appending(user: "请叫我小林", assistant: "好的")
            .appending(user: "我喜欢茶", assistant: "记下了")
        return try MemoryExtractionSnapshot(conversation: value, model: .flash)
    }
    private func decode(_ values: [[String: Any]], memories: [ChatMemory] = []) throws -> MemoryCandidateBatch {
        try MemoryCandidateDecoder.decode(JSONSerialization.data(withJSONObject: ["candidates": values]), for: snapshot(memories: memories))
    }
    func testCanonicalTextAndLimits() throws {
        XCTAssertEqual(try ChatMemory(text: " e\u{301} \n").text, "é")
        XCTAssertNoThrow(try ChatMemory(text: String(repeating: "😀", count: 100)))
        XCTAssertThrowsError(try ChatMemory(text: String(repeating: "😀", count: 100) + "x"))
        for bad in [" \n\t", "a\0b"] { XCTAssertThrowsError(try ChatMemory(text: bad)) }
    }
    func testListCapacityDuplicatesAndRevision() throws {
        let list = try (0..<20).map { try ChatMemory(text: "记忆\($0)") }
        XCTAssertNoThrow(try ChatMemory.validate(list))
        XCTAssertThrowsError(try ChatMemory.validate(list + [ChatMemory(text: "第21条")]))
        XCTAssertThrowsError(try ChatMemory.validate([list[0], ChatMemory(id: list[0].id, text: "另一条")]))
        XCTAssertThrowsError(try ChatMemory.validate([ChatMemory(text: "é"), ChatMemory(text: " e\u{301} ")]))
        let empty = try ChatConversation(characterID: "robin")
        let saved = try empty.replacingMemories(list, expectedRevision: 0)
        XCTAssertEqual(saved.memoryRevision, 1)
        XCTAssertEqual(saved.memories, list)
        XCTAssertThrowsError(try saved.replacingMemories([], expectedRevision: 0))
        let overflow = try ChatConversation(characterID: "robin", memoryRevision: .max)
        XCTAssertThrowsError(try overflow.replacingMemories([], expectedRevision: .max))
    }
    func testPromptsKeepMemoriesAfterThirteenRounds() throws {
        let memory = try ChatMemory(text: "用户喜欢乌龙茶")
        var state = try ChatConversation(characterID: "robin", profile: .init(background: "PERSONA-NOT-EXTRACTION"), memories: [memory], memoryRevision: 7)
        for number in 1...13 { state = try state.appending(user: "u\(number)", assistant: "a\(number)") }
        XCTAssertEqual(state.messages.count, 24)
        XCTAssertEqual(state.messages.first?.content, "u2")
        XCTAssertEqual(state.memoryRevision, 7)
        let prompt = try ChatPromptSnapshot(characterID: "robin", characterName: "知更鸟", conversation: state, model: .pro, input: "DRAFT-ONLY-CHAT")
        XCTAssertTrue(prompt.messages[0].content.contains(memory.text))
        XCTAssertEqual(prompt.memoryRevision, 7)
        let extraction = try MemoryExtractionSnapshot(conversation: state, model: .pro)
        let text = extraction.messages.map(\.content).joined()
        XCTAssertFalse(text.contains("PERSONA-NOT-EXTRACTION"))
        XCTAssertFalse(text.contains("DRAFT-ONLY-CHAT"))
        XCTAssertTrue(text.contains(memory.text))
        XCTAssertEqual(extraction.rounds.first?.user, "u2")
        XCTAssertEqual(try state.replacingProfile(.init(personality: "新设定")).memories, [memory])
        XCTAssertEqual(try state.clearingHistory().memoryRevision, 7)
        XCTAssertThrowsError(try MemoryExtractionSnapshot(conversation: ChatConversation(characterID: "robin"), model: .flash))
    }
    func testCandidateJSONContractAndGroundedSource() throws {
        XCTAssertEqual(try decode([]).candidates.count, 0)
        let five = (0..<5).map { ["text": "内容\($0)", "sourceRounds": [1, 2, 1]] as [String: Any] }
        XCTAssertEqual(try decode(five).candidates.count, 5)
        XCTAssertEqual(try decode(five).candidates[0].sourceRounds, [1, 2])
        XCTAssertThrowsError(try decode(five + [["text": "六", "sourceRounds": [1]]]))
        for sources: Any in [[], [0], [3], ["1"], [true], [1.5]] {
            XCTAssertThrowsError(try decode([["text": "候选", "sourceRounds": sources]]))
        }
        for text in [" ", "\0", String(repeating: "字", count: 201)] {
            XCTAssertThrowsError(try decode([["text": "有效", "sourceRounds": [1]], ["text": text, "sourceRounds": [2]]]))
        }
        XCTAssertThrowsError(try decode([["text": "候选", "sourceRounds": [1], "delete": true]]))
        for raw in [#"{"candidates":[],"extra":true}"#, #"{"candidates":[],"candidates":[]}"#, #"{"candidates":null}"#] {
            XCTAssertThrowsError(try MemoryCandidateDecoder.decode(Data(raw.utf8), for: snapshot()))
        }
        XCTAssertThrowsError(try MemoryCandidateDecoder.decode(Data(repeating: 32, count: 16385), for: snapshot()))
    }
    func testExactDuplicateCandidatesAreReported() throws {
        let batch = try decode([
            ["text": " e\u{301} ", "sourceRounds": [1]],
            ["text": "喜欢茶", "sourceRounds": [2]],
            ["text": " 喜欢茶 ", "sourceRounds": [2]],
            ["text": "爱喝茶", "sourceRounds": [2]]
        ], memories: [ChatMemory(text: "é")])
        XCTAssertEqual(batch.candidates.map(\.text), ["喜欢茶", "爱喝茶"])
        XCTAssertEqual(batch.duplicateCount, 2)
        XCTAssertEqual(Set(batch.candidates.map(\.id)).count, 2)
    }
}
