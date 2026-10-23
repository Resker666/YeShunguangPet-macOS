import Foundation
import XCTest
import PetCore

@MainActor final class ChatPersistenceTests: XCTestCase {
    private func fixture(seed: ChatConversation? = nil) throws -> (URL, ControlledChatPersistence, ChatWriteQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-persistence-" + UUID().uuidString)
        if let seed { try ChatStore(directory: root.appendingPathComponent("AI/characters")).save(seed) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json"))
        return (root, persistence, ChatWriteQueue(persistence: persistence))
    }
    private func loaded(_ root: URL) throws -> ChatConversation {
        guard case .loaded(let state) = ChatStore(directory: root.appendingPathComponent("AI/characters")).load(characterID: "robin") else {
            throw NSError(domain: "ChatArchiveNotSaved", code: 1)
        }
        return state
    }

    func testAcceptedAppendThenClearRemainsEmpty() async throws {
        let (root, persistence, queue) = try fixture()
        _ = await persistence.loadCharacter(id: "robin", defaultProfile: .init(background: "保留人设"))
        await persistence.holdNextWrite()
        var receipts = [UInt64]()
        queue.enqueue(.append(characterID: "robin", user: "问", assistant: "答")) { ticket, result in
            if case .failure = result { XCTFail("append failed") }; receipts.append(ticket.sequence)
        }
        await persistence.waitForOperations(1)
        queue.enqueue(.clear(characterID: "robin")) { ticket, result in
            if case .failure = result { XCTFail("clear failed") }; receipts.append(ticket.sequence)
        }
        for _ in 0..<20 { await Task.yield() }
        let beforeRelease = await persistence.operations
        XCTAssertEqual(beforeRelease, ["append:robin"])
        await persistence.releaseWrite()
        await queue.waitForPending()
        XCTAssertEqual(receipts, [1, 2])
        XCTAssertEqual(try loaded(root).messages.count, 0)
        XCTAssertEqual(try loaded(root).profile.background, "保留人设")
    }

    func testClearFailurePreservesCommittedState() async throws {
        for appendFails in [false, true] {
            let seed = try ChatConversation(characterID: "robin").appending(user: "原问", assistant: "原答")
            let (root, persistence, queue) = try fixture(seed: seed)
            if appendFails { await persistence.failNext("append:robin") }
            await persistence.failNext("clear:robin")
            var failures = [UInt64]()
            queue.enqueue(.append(characterID: "robin", user: "新问", assistant: "新答")) { ticket, result in
                if case .failure = result { failures.append(ticket.sequence) }
            }
            queue.enqueue(.clear(characterID: "robin")) { ticket, result in
                if case .failure = result { failures.append(ticket.sequence) }
            }
            await queue.waitForPending()
            XCTAssertEqual(failures, appendFails ? [1, 2] : [2])
            let state = try loaded(root)
            XCTAssertEqual(state.messages.map(\.content), appendFails ? ["原问", "原答"] : ["原问", "原答", "新问", "新答"])
        }
    }

    func testAcceptedMutationSurvivesRequestCancellation() async throws {
        let (root, persistence, queue) = try fixture()
        await persistence.holdNextWrite()
        let caller = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChatStoredValue, Error>) in
                queue.enqueue(.append(characterID: "robin", user: "旧角色问题", assistant: "旧角色回答")) { _, result in
                    continuation.resume(with: result)
                }
            }
        }
        await persistence.waitForOperations(1)
        caller.cancel()
        await persistence.releaseWrite()
        let result = try await caller.value
        guard case .character(let conversation) = result else { return XCTFail("wrong receipt") }
        XCTAssertEqual(conversation.characterID, "robin")
        XCTAssertEqual(try loaded(root).messages.count, 2)
        await queue.waitForPending()
    }

    func testQueueDrainsBeforeExit() async throws {
        let (_, persistence, queue) = try fixture()
        await persistence.holdNextWrite()
        queue.enqueue(.profile(characterID: "robin", profile: .init(personality: "温柔"))) { _, result in
            if case .failure = result { XCTFail("profile write failed") }
        }
        await persistence.waitForOperations(1)
        let flag = ChatTestFlag()
        let waiting = Task { @MainActor in await queue.waitForPending(); flag.value = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(queue.hasPending)
        XCTAssertFalse(flag.value)
        await persistence.releaseWrite()
        await waiting.value
        XCTAssertFalse(queue.hasPending)
        XCTAssertTrue(flag.value)
    }
}
