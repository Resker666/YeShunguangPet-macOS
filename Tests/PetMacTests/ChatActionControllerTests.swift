import Foundation
import XCTest
import PetCore

@MainActor final class ChatActionControllerTests: XCTestCase {
    private func fixture(canDispatch: @escaping () -> Bool = { true }) async throws -> ChatControllerFixture {
        let f = try ChatControllerFixture(canDispatch: canDispatch); addTeardownBlock { await f.close() }; try await f.open(); return f
    }
    private func propose(_ f: ChatControllerFixture, input: String = "暂停专注", action: ChatAction = .pauseFocus) async throws -> ChatActionProposal {
        let index = f.client.count
        f.controller.setDraft(input); f.controller.send()
        try await chatEventually { f.client.count == index + 1 }
        XCTAssertNotNil(f.client.snapshot(index)?.appSnapshot)
        f.client.emit(index, "我已执行（不可信预览）")
        f.client.propose(index, action: action)
        try await chatEventually { f.controller.pendingAction != nil }
        return try XCTUnwrap(f.controller.pendingAction)
    }
    func testProposalNeedsExplicitDecisionAndOneRequest() async throws {
        let f = try await fixture(), card = try await propose(f)
        XCTAssertTrue(f.actions.executions.isEmpty); XCTAssertFalse(f.controller.hasPendingWrites)
        XCTAssertEqual(f.controller.conversation?.messages.count, 0); XCTAssertEqual(f.controller.draft, "暂停专注")
        XCTAssertEqual(f.controller.partialReply, ""); XCTAssertEqual(f.controller.state, .awaitingAction)
        XCTAssertFalse(f.controller.canSend); XCTAssertFalse(f.controller.canEditProfile); XCTAssertFalse(f.controller.canExtractMemories)
        f.controller.send(); f.controller.extractMemories(); f.controller.applyProfile(.init(background: "不能保存"))
        f.controller.confirmAction(id: UUID(), for: card.context); XCTAssertTrue(f.actions.executions.isEmpty)
        f.controller.confirmAction(id: card.id, for: card.context); f.controller.confirmAction(id: card.id, for: card.context)
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.actions.executions, [.pauseFocus]); XCTAssertEqual(f.client.count, 1)
        let reads = await f.credentials.reads; XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.controller.conversation?.messages.count, 2)
        XCTAssertTrue(f.controller.conversation?.messages.last?.content.hasPrefix("【App操作回执】") == true)
        XCTAssertTrue(f.feedback.lines.isEmpty)
        let cancel = try await propose(f)
        f.controller.cancelAction(id: cancel.id, for: cancel.context); await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.actions.executions.count, 1)
        XCTAssertTrue(f.controller.conversation?.messages.last?.content.contains("已取消，未执行") == true)
        let expired = try await propose(f); f.actions.expires = true
        f.controller.confirmAction(id: expired.id, for: expired.context)
        XCTAssertNil(f.controller.pendingAction); XCTAssertEqual(f.controller.conversation?.messages.count, 4)
        XCTAssertEqual(f.controller.draft, "暂停专注"); XCTAssertNotNil(f.controller.error)
    }
    func testAcceptedReceiptSurvivesSynchronousCloseSwitchAndQuit() async throws {
        for event in ["close", "same-id", "other-id", "quit"] {
            let f = try await fixture(), card = try await propose(f)
            f.actions.onExecute = {
                XCTAssertTrue(f.controller.hasPendingWrites)
                f.controller.confirmAction(id: card.id, for: card.context)
                switch event {
                case "close": f.controller.windowClosed()
                case "same-id": f.controller.activate(.init(id: "robin", name: "robin", description: "", skinRevision: 1))
                case "other-id": f.controller.activate(.init(id: "hutao", name: "hutao", description: "", skinRevision: 1))
                default: f.controller.beginTermination()
                }
            }
            f.controller.confirmAction(id: card.id, for: card.context); await f.controller.waitForPendingWrites()
            XCTAssertEqual(f.actions.executions.count, 1, event)
            let result = await f.persistence.worker.loadCharacter(id: "robin", defaultProfile: .init())
            guard case .loaded(let old) = result else { return XCTFail("lost old-role receipt \(event)") }
            XCTAssertEqual(old.messages.count, 2, event); XCTAssertTrue(old.messages.last!.content.contains("App操作回执"))
            if event == "other-id" { try await chatEventually { f.controller.conversation?.characterID == "hutao" }; XCTAssertTrue(f.controller.conversation?.messages.isEmpty == true) }
            XCTAssertTrue(f.feedback.lines.isEmpty)
        }
    }
    func testFailedReceiptRetryNeverExecutesAgain() async throws {
        for outcome in [ChatActionReceipt.Outcome.applied, .failed, .cancelled] {
            let f = try await fixture(); f.actions.outcome = outcome
            let card = try await propose(f); await f.persistence.failNext("append:robin")
            if outcome == .cancelled { f.controller.cancelAction(id: card.id, for: card.context) }
            else { f.controller.confirmAction(id: card.id, for: card.context) }
            await f.controller.waitForPendingWrites()
            XCTAssertEqual(f.controller.state, .unsaved); XCTAssertEqual(f.controller.unsavedCharacterIDs, ["robin"])
            XCTAssertTrue(f.controller.error?.contains(outcome == .applied ? "操作已执行" : (outcome == .cancelled ? "已取消" : "未完成")) == true)
            let receipt = f.controller.partialReply
            f.controller.windowClosed(); try await f.open("hutao"); f.controller.beginTermination()
            let saved = await f.controller.retryAllPendingSaves(); XCTAssertTrue(saved)
            XCTAssertEqual(f.actions.executions.count, outcome == .cancelled ? 0 : 1)
            XCTAssertEqual(f.client.count, 1); let reads = await f.credentials.reads; XCTAssertEqual(reads, 1)
            f.controller.cancelTermination(); try await f.open()
            XCTAssertEqual(f.controller.conversation?.messages.last?.content, receipt)
        }
        let f = try await fixture(), card = try await propose(f); await f.persistence.failNext("append:robin")
        f.controller.confirmAction(id: card.id, for: card.context); await f.controller.waitForPendingWrites()
        f.controller.discardPendingSave(); XCTAssertEqual(f.actions.executions.count, 1); XCTAssertFalse(f.controller.canRetryPendingSave)
    }
    func testDraftAndMemoryReviewSurviveActionRound() async throws {
        let f = try ChatControllerFixture(); addTeardownBlock { await f.close() }
        var archive = try ChatConversation(characterID: "robin")
        for i in 1...12 { archive = try archive.appending(user: "u\(i)", assistant: "a\(i)") }
        try ChatStore(directory: f.root.appendingPathComponent("AI/characters")).save(archive); try await f.open()
        f.controller.extractMemories(); try await chatEventually { f.memoryClient.count == 1 }
        f.memoryClient.complete(0, json: #"{"candidates":[{"text":"记忆候选","sourceRounds":[1]}]}"#)
        try await chatEventually { f.controller.memoryReview != nil }
        let review = try XCTUnwrap(f.controller.memoryReview), candidate = try XCTUnwrap(review.candidates.first)
        f.controller.setMemoryCandidateSelected(id: candidate.id, selected: true)
        let card = try await propose(f)
        f.controller.setDraft("新写的下一条"); f.controller.saveSelectedMemories(reviewID: review.id, for: review.context)
        XCTAssertFalse(f.controller.hasPendingWrites); XCTAssertEqual(f.controller.memoryReview?.id, review.id)
        await f.persistence.holdNextWrite(); f.controller.confirmAction(id: card.id, for: card.context)
        await f.persistence.waitForOperations(1); XCTAssertFalse(f.controller.canEditMemories)
        await f.persistence.releaseWrite(); await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.draft, "新写的下一条")
        XCTAssertEqual(f.controller.conversation?.messages.first?.content, "u2")
        XCTAssertEqual(f.controller.memoryReview?.snapshot.rounds.first?.user, "u1")
        XCTAssertTrue(f.controller.canEditMemories)
        f.controller.saveSelectedMemories(reviewID: review.id, for: review.context); await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.memories.first?.text, "记忆候选")
    }
    func testUnacceptedActionsCannotReviveAfterInvalidation() async throws {
        for event in ["stop", "close", "same-id", "other-id", "sleep", "off", "quit", "clear", "reset", "bridge-change"] {
            let f = try await fixture(), card = try await propose(f)
            switch event {
            case "stop": f.controller.stop()
            case "close": f.controller.windowClosed()
            case "same-id": try await f.open("robin", revision: 1)
            case "other-id": try await f.open("hutao")
            case "sleep": f.controller.setSleeping(true); f.controller.setSleeping(false)
            case "off": f.controller.saveConnection(.init(enabled: false))
            case "quit": f.controller.beginTermination(); f.controller.cancelTermination()
            case "clear": f.controller.clearHistory()
            case "reset": f.controller.resetCharacterArchive()
            default: f.actions.change()
            }
            await f.controller.waitForPendingWrites()
            f.controller.confirmAction(id: card.id, for: card.context)
            XCTAssertNil(f.controller.pendingAction, event); XCTAssertTrue(f.actions.executions.isEmpty, event)
        }
        let modal = ChatTestFlag(), f = try await fixture(canDispatch: { !modal.value }), card = try await propose(f)
        modal.value = true; f.controller.refreshActionAvailability(); f.controller.confirmAction(id: card.id, for: card.context)
        XCTAssertNotNil(f.controller.pendingAction); XCTAssertTrue(f.actions.executions.isEmpty)
        modal.value = false; f.controller.setPresented(false); f.controller.refreshActionAvailability()
        XCTAssertNotNil(f.controller.pendingAction); f.controller.confirmAction(id: card.id, for: card.context)
        await f.controller.waitForPendingWrites(); XCTAssertEqual(f.actions.executions.count, 1)
        let late = try await fixture(); late.controller.setDraft("晚到操作"); late.controller.send()
        try await chatEventually { late.client.count == 1 }; late.controller.stop(); late.client.propose(0, action: .pauseFocus)
        await Task.yield(); XCTAssertNil(late.controller.pendingAction); XCTAssertTrue(late.actions.executions.isEmpty)
    }
}
