import Foundation
import XCTest
import PetCore

final class ChatConversationTests: XCTestCase {
    // Dropping one message instead of a full round would put a13 or u1 at an edge.
    func testThirteenPairsRetainsNewestTwelve() throws {
        var state = try ChatConversation(characterID: "ye-shunguang")
        for i in 1...13 { state = try state.appending(user: "u\(i)", assistant: "a\(i)") }
        XCTAssertEqual(state.messages.count, 24)
        XCTAssertEqual(state.messages.first?.content, "u2")
        XCTAssertEqual(state.messages.last?.content, "a13")
        let reopened = try JSONDecoder().decode(ChatConversation.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened, state)
    }

    // Counting Character instead of UTF-16 would accept twice the intended input.
    func testUTF16AndWholeGraphemeLimits() throws {
        let state = try ChatConversation(characterID: "ye-shunguang")
        XCTAssertNoThrow(try state.appending(user: String(repeating: "😀", count: 1000), assistant: String(repeating: "答", count: 8000)))
        XCTAssertThrowsError(try state.appending(user: String(repeating: "😀", count: 1001), assistant: "答"))
        XCTAssertThrowsError(try state.appending(user: "问", assistant: String(repeating: "答", count: 8001)))
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(ChatText.excerpt(String(repeating: "x", count: 75) + family), String(repeating: "x", count: 75) + "…")
        XCTAssertEqual(ChatText.excerpt("你好\n\n世界\t😀"), "你好 世界 😀")
        XCTAssertEqual(ChatText.excerpt("x", limit: 0), "")
        XCTAssertNoThrow(try ChatText.validate("多行\n第二行\t好\r\n", maxUTF16: 80, allowEmpty: false))
        XCTAssertThrowsError(try ChatText.validate("危险\0文字", maxUTF16: 80, allowEmpty: false))
        XCTAssertThrowsError(try ChatText.validate(" \n\t", maxUTF16: 80, allowEmpty: false))
    }

    // A mismatched persona, extra history or a half-turn must never be sent.
    func testProfileAndPromptContract() throws {
        let profile = ChatProfile(background: "背景", personality: "友善", speakingStyle: "简短", examples: "你好呀")
        XCTAssertNoThrow(try ChatProfile().validate())
        XCTAssertNoThrow(try ChatProfile(background: String(repeating: "字", count: 2000), personality: String(repeating: "字", count: 1000), speakingStyle: String(repeating: "字", count: 1000), examples: String(repeating: "字", count: 2000)).validate())
        for bad in [
            ChatProfile(background: String(repeating: "字", count: 2001)),
            ChatProfile(personality: String(repeating: "字", count: 1001)),
            ChatProfile(speakingStyle: String(repeating: "字", count: 1001)),
            ChatProfile(examples: String(repeating: "字", count: 2001)),
            ChatProfile(background: "\0")
        ] { XCTAssertThrowsError(try bad.validate()) }
        let conversation = try ChatConversation(characterID: "ye-shunguang", profile: profile)
            .appending(user: "上条问题", assistant: "上条回答")
        let snapshot = try ChatPromptSnapshot(characterID: "ye-shunguang", characterName: "叶瞬光", conversation: conversation, model: .flash, input: "本次问题")
        XCTAssertEqual(snapshot.messages.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertTrue(snapshot.messages[0].content.contains("叶瞬光"))
        for text in ["背景", "友善", "简短", "你好呀"] { XCTAssertTrue(snapshot.messages[0].content.contains(text)) }
        XCTAssertEqual(snapshot.messages[1].content, "上条问题")
        XCTAssertEqual(snapshot.messages[2].content, "上条回答")
        XCTAssertEqual(snapshot.messages[3].content, "本次问题")
        XCTAssertThrowsError(try ChatPromptSnapshot(characterID: "robin", characterName: "知更鸟", conversation: conversation, model: .pro, input: "问"))
        XCTAssertThrowsError(try ChatPromptSnapshot(characterID: "ye-shunguang", characterName: "叶瞬光", conversation: conversation, model: .flash, input: " \n"))
        for id in ["../escape", "Bad", "con", ""] { XCTAssertThrowsError(try ChatConversation(characterID: id)) }
        XCTAssertThrowsError(try ChatConversation(characterID: "robin", messages: [.init(role: .user, content: "半条")]))
        XCTAssertThrowsError(try ChatConversation(characterID: "robin", messages: [.init(role: .assistant, content: "错"), .init(role: .user, content: "序")]))
        XCTAssertThrowsError(try ChatConversation(characterID: "robin", messages: [.init(role: .system, content: "错"), .init(role: .assistant, content: "序")]))
    }
}
