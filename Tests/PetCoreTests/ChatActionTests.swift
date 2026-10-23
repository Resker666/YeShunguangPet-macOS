import Foundation
import XCTest
import PetCore

final class ChatActionTests: XCTestCase {
    // Relaxing strict types/fields would allow an ambiguous command to reach the bridge.
    func testActionArgumentsRejectWrongTypesAndUnknownFields() throws {
        for n in [1, 120] {
            XCTAssertEqual(try ChatActionDecoder.decode(name: "start_focus", arguments: Data("{\"minutes\":\(n)}".utf8)), .startFocus(minutes: n))
        }
        for bad in ["{}", "{\"minutes\":0}", "{\"minutes\":121}", "{\"minutes\":1.5}", "{\"minutes\":1.0}", "{\"minutes\":true}", "{\"minutes\":\"25\"}", "{\"minutes\":25,\"extra\":1}", "{\"minutes\":25,\"minutes\":26}"] {
            XCTAssertThrowsError(try ChatActionDecoder.decode(name: "start_focus", arguments: Data(bad.utf8)), bad)
        }
        XCTAssertEqual(try ChatActionDecoder.decode(name: "pause_focus", arguments: Data("{}".utf8)), .pauseFocus)
        XCTAssertEqual(try ChatActionDecoder.decode(name: "resume_focus", arguments: Data("{}".utf8)), .resumeFocus)
        for name in ["pause_focus", "resume_focus", "unknown"] {
            XCTAssertThrowsError(try ChatActionDecoder.decode(name: name, arguments: Data("{\"extra\":0}".utf8)))
        }
        for enabled in [true, false] {
            XCTAssertEqual(try ChatActionDecoder.decode(name: "set_quiet", arguments: Data("{\"enabled\":\(enabled)}".utf8)), .setQuiet(enabled: enabled))
        }
        for bad in ["{}", "{\"enabled\":1}", "{\"enabled\":\"true\"}", "{\"enabled\":null}", "{\"enabled\":true,\"x\":0}"] {
            XCTAssertThrowsError(try ChatActionDecoder.decode(name: "set_quiet", arguments: Data(bad.utf8)))
        }
        XCTAssertThrowsError(try ChatActionDecoder.decode(name: "pause_focus", arguments: Data(("{}" + String(repeating: " ", count: 4095)).utf8)))
    }

    func testStampIgnoresCountdownButDetectsRevisionAndState() {
        func state(_ f: UInt64 = 0, _ q: UInt64 = 0, _ phase: FocusPhase = .focus, _ status: FocusStatus = .running, _ focus: Int = 25, _ rest: Int = 5, _ seconds: Int = 100, _ manual: Bool = false, _ automatic: Bool = true) -> ChatAppSnapshot {
            .init(focusRevision: f, quietRevision: q, phase: phase, status: status, focusMinutes: focus, breakMinutes: rest, remainingSeconds: seconds, manualQuiet: manual, focusQuiet: automatic)
        }
        let original = state()
        XCTAssertEqual(original.commandStamp, state(0, 0, .focus, .running, 25, 5, 99).commandStamp)
        for changed in [state(1), state(0, 1), state(0, 0, .rest), state(0, 0, .focus, .paused), state(0, 0, .focus, .running, 26), state(0, 0, .focus, .running, 25, 6), state(0, 0, .focus, .running, 25, 5, 100, true), state(0, 0, .focus, .running, 25, 5, 100, false, false)] {
            XCTAssertNotEqual(original.commandStamp, changed.commandStamp)
        }
    }

    func testPromptAddsReadOnlyRuntimeWithoutChangingMemoryContract() throws {
        var conversation = try ChatConversation(characterID: "robin", profile: .init(background: "自定义背景"), memories: [.init(id: UUID(), text: "喜欢咖啡")])
        for i in 1...12 { conversation = try conversation.appending(user: "问\(i)", assistant: "答\(i)") }
        let old = try ChatPromptSnapshot(characterID: "robin", characterName: "知更鸟", conversation: conversation, model: .flash, input: " 输入 ")
        XCTAssertNil(old.appSnapshot)
        let state = ChatAppSnapshot(focusRevision: 987654, quietRevision: 987655, phase: .focus, status: .ready, focusMinutes: 25, breakMinutes: 5, remainingSeconds: 1500, manualQuiet: false, focusQuiet: false)
        let prompt = try ChatPromptSnapshot(characterID: "robin", characterName: "知更鸟", conversation: conversation, model: .flash, input: " 输入 ", appSnapshot: state)
        XCTAssertEqual(prompt.appSnapshot, state)
        XCTAssertEqual(Array(prompt.messages.dropFirst()), Array(old.messages.dropFirst()))
        let system = prompt.messages[0].content
        for text in ["自定义背景", "喜欢咖啡", "start_focus", "pause_focus", "resume_focus", "set_quiet", "1–120", "尚未执行", "remainingSeconds"] { XCTAssertTrue(system.contains(text), text) }
        for text in ["987654", "987655", "Revision", "/Users/"] { XCTAssertFalse(system.contains(text), text) }
        XCTAssertFalse(old.messages[0].content.contains("start_focus"))
        XCTAssertFalse(try MemoryExtractionSnapshot(conversation: conversation, model: .flash).messages.map(\.content).joined().contains("remainingSeconds"))
        let receipt = try ChatActionReceipt(action: .pauseFocus, outcome: .applied, detail: "已暂停当前专注。")
        XCTAssertTrue(receipt.assistantText.hasPrefix("【App操作回执】"))
        XCTAssertNoThrow(try conversation.appending(user: "暂停", assistant: receipt.assistantText).validate())
        XCTAssertThrowsError(try ChatActionReceipt(action: .pauseFocus, outcome: .failed, detail: "\0"))
    }
}
