import Foundation
import XCTest
import PetCore

@MainActor final class MemoryExtractionTests: XCTestCase {
    private let valid = #"{"candidates":[{"text":"候选记忆A","sourceRounds":[1]},{"text":"候选记忆B","sourceRounds":[1]}]}"#
    private func fixture(rounds: Int = 1, memories: [ChatMemory] = []) async throws -> ChatControllerFixture {
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }
        var state = try ChatConversation(characterID: "robin", memories: memories)
        for number in 0..<rounds { state = try state.appending(user: "u\(number + 1)", assistant: "a\(number + 1)") }
        try ChatStore(directory: f.root.appendingPathComponent("AI/characters")).save(state)
        try await f.open()
        return f
    }
    private func extract(_ f: ChatControllerFixture) async throws -> MemoryReviewState {
        let index = f.memoryClient.count
        f.controller.extractMemories()
        try await chatEventually { f.memoryClient.count == index + 1 }
        f.memoryClient.complete(index, json: valid)
        try await chatEventually { f.controller.memoryReview != nil }
        return try XCTUnwrap(f.controller.memoryReview)
    }
    func testCandidatesRequireExplicitSelectionAndNeverEnterChatUntilSaved() async throws {
        let f = try await fixture()
        f.controller.setDraft("保留草稿")
        let before = f.controller.conversation
        let files = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("AI/characters"), includingPropertiesForKeys: nil)
        let url = try XCTUnwrap(files.first), bytes = try Data(contentsOf: url)
        let review = try await extract(f)
        XCTAssertTrue(review.selectedIDs.isEmpty)
        XCTAssertEqual(f.controller.conversation, before)
        XCTAssertEqual(f.controller.draft, "保留草稿")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(f.feedback.lines.isEmpty)
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        XCTAssertFalse(f.controller.hasPendingWrites)
        let candidate = try XCTUnwrap(review.candidates.first)
        f.controller.setMemoryCandidateText(id: candidate.id, text: " 确认后的内容 ")
        f.controller.setMemoryCandidateSelected(id: candidate.id, selected: true)
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.memories.map(\.text), ["确认后的内容"])
        XCTAssertNil(f.controller.memoryReview)
        XCTAssertEqual(f.memoryClient.count, 1)
        XCTAssertEqual(f.client.count, 0)
    }
    func testCompletedReviewSurvivesNormalChatButKeepsOriginalSources() async throws {
        let f = try await fixture(rounds: 12)
        let review = try await extract(f), candidate = try XCTUnwrap(review.candidates.first)
        try await f.send("u13", answer: "a13", index: 0)
        XCTAssertEqual(f.controller.conversation?.messages.first?.content, "u2")
        XCTAssertEqual(f.controller.memoryReview?.id, review.id)
        XCTAssertEqual(f.controller.memoryReview?.snapshot.rounds.first?.user, "u1")
        XCTAssertFalse(try XCTUnwrap(f.client.snapshot(0)).messages[0].content.contains(candidate.text))
        f.controller.setMemoryCandidateSelected(id: candidate.id, selected: true)
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        await f.controller.waitForPendingWrites()
        f.controller.setDraft("u14"); f.controller.send()
        try await chatEventually { f.client.count == 2 }
        XCTAssertTrue(try XCTUnwrap(f.client.snapshot(1)).messages[0].content.contains(candidate.text))
    }
    func testLateExtractionCannotReviveDiscardedBatch() async throws {
        for action in ["stop", "close", "role", "same-id", "sleep", "off", "quit"] {
            for reading in [false, true] {
                let f = try await fixture()
                if reading { await f.credentials.holdNextRead() }
                f.controller.extractMemories()
                if reading { await f.credentials.waitForReads(1) }
                else { try await chatEventually { f.memoryClient.count == 1 } }
                switch action {
                case "stop": f.controller.stop()
                case "close": f.controller.windowClosed()
                case "role": try await f.open("hutao")
                case "same-id": try await f.open("robin", revision: 1)
                case "sleep": f.controller.setSleeping(true)
                case "off": f.controller.saveConnection(.init(enabled: false))
                default: f.controller.beginTermination()
                }
                if reading { await f.credentials.releaseRead() }
                else { f.memoryClient.complete(0, json: valid) }
                for _ in 0..<20 { await Task.yield() }
                await f.controller.waitForPendingWrites()
                XCTAssertNil(f.controller.memoryReview, action)
                XCTAssertTrue(f.controller.conversation?.memories.isEmpty == true)
                XCTAssertEqual(f.memoryClient.count, reading ? 0 : 1)
                XCTAssertTrue(f.feedback.lines.isEmpty)
                if action == "quit" { f.controller.cancelTermination(); XCTAssertFalse(f.controller.isGenerating) }
            }
        }
    }
    func testMemoryReviewInvalidationDoesNotLoseAcceptedIntent() async throws {
        for action in ["profile", "memory", "clear", "reset", "close", "skin", "quit"] {
            let f = try await fixture(memories: [ChatMemory(text: "旧记忆")])
            let review = try await extract(f)
            switch action {
            case "profile": f.controller.applyProfile(.init(background: "新背景"))
            case "memory": f.controller.clearMemories(for: review.context, expectedRevision: 0)
            case "clear": f.controller.clearHistory()
            case "reset": f.controller.resetCharacterArchive()
            case "close": f.controller.windowClosed()
            case "skin": try await f.open("robin", revision: 1)
            default: f.controller.beginTermination()
            }
            await f.controller.waitForPendingWrites()
            XCTAssertNil(f.controller.memoryReview, action)
        }
        let f = try await fixture(), review = try await extract(f)
        f.controller.setMemoryCandidateSelected(id: try XCTUnwrap(review.candidates.first).id, selected: true)
        await f.persistence.failNext("memories:robin")
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        await f.controller.waitForPendingWrites()
        f.controller.windowClosed(); try await f.open("hutao")
        XCTAssertEqual(f.controller.pendingMemoryCharacterIDs, ["robin"])
        let success = await f.controller.retryAllPendingSaves(); XCTAssertTrue(success)
        XCTAssertEqual(f.memoryClient.count, 1)
    }
    func testAIRequestKindsAreSingleFlight() async throws {
        let f = try await fixture()
        f.controller.setDraft("聊天草稿"); f.controller.extractMemories(); f.controller.send()
        try await chatEventually { f.memoryClient.count == 1 }
        XCTAssertEqual(f.client.count, 0)
        XCTAssertTrue(f.controller.isExtractingMemories)
        XCTAssertFalse(f.controller.canChangeConnection)
        XCTAssertFalse(f.controller.canEditMemories)
        f.controller.stop()
        XCTAssertTrue(f.controller.error?.contains("提炼") == true)
        f.controller.send(); f.controller.extractMemories()
        try await chatEventually { f.client.count == 1 }
        XCTAssertEqual(f.memoryClient.count, 1)
        f.controller.saveConnection(.init(enabled: false)); await f.controller.waitForPendingWrites()
        XCTAssertFalse(f.controller.isGenerating)
        f.client.complete(0, answer: "晚到")
        f.memoryClient.complete(0, json: valid)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.controller.conversation?.messages.count, 2)
        f.controller.saveConnection(.init(enabled: true)); await f.controller.waitForPendingWrites()
        let review = try await extract(f)
        f.controller.setSleeping(true); f.controller.setSleeping(false)
        f.controller.saveConnection(.init(enabled: false)); await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.memoryReview?.id, review.id)
        f.controller.setMemoryCandidateSelected(id: try XCTUnwrap(review.candidates.first).id, selected: true)
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.memories.count, 1)
    }
    func testCapacityInvalidEditsAndEmptyHistoryNeverTriggerImplicitRequests() async throws {
        let full = try await fixture(memories: (0..<20).map { try ChatMemory(text: "旧\($0)") })
        full.controller.extractMemories(); XCTAssertFalse(full.controller.canExtractMemories)
        XCTAssertEqual(full.memoryClient.count, 0)
        let empty = try await fixture(rounds: 0)
        empty.controller.extractMemories(); XCTAssertFalse(empty.controller.canExtractMemories)
        let reads = await empty.credentials.reads; XCTAssertEqual(reads, 0)
        let f = try await fixture(memories: (0..<19).map { try ChatMemory(text: "旧\($0)") })
        let review = try await extract(f)
        for candidate in review.candidates { f.controller.setMemoryCandidateSelected(id: candidate.id, selected: true) }
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        XCTAssertFalse(f.controller.hasPendingWrites)
        let first = review.candidates[0], second = review.candidates[1]
        f.controller.setMemoryCandidateSelected(id: second.id, selected: false)
        for text in ["旧0", String(repeating: "字", count: 201)] {
            f.controller.setMemoryCandidateText(id: first.id, text: text)
            f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
            XCTAssertFalse(f.controller.hasPendingWrites)
            XCTAssertEqual(f.controller.memoryReview?.editedTexts[first.id], text)
        }
        f.controller.setMemoryCandidateText(id: first.id, text: "最终确认")
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.memories.count, 20)
        XCTAssertEqual(f.memoryClient.count, 1)
    }
}
