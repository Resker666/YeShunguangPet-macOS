import Foundation
import XCTest
import PetCore

@MainActor final class ChatControllerTests: XCTestCase {
    private func fixture() throws -> ChatControllerFixture {
        let value = try ChatControllerFixture()
        addTeardownBlock { await value.close() }
        return value
    }
    func testManualSingleFlightAndTwelveRoundReopen() async throws {
        let f = try fixture()
        try await f.open()
        XCTAssertEqual(f.client.count, 0)
        let initialReads = await f.credentials.reads; XCTAssertEqual(initialReads, 0)
        f.controller.saveConnection(.init(enabled: true, model: .flash))
        await f.controller.waitForPendingWrites()
        for i in 1...13 {
            f.controller.setDraft("问\(i)"); f.controller.send(); f.controller.send()
            try await chatEventually { f.client.count == i }
            f.client.complete(i - 1, answer: "答\(i)")
            try await chatEventually { f.controller.state == .idle && !f.controller.hasPendingWrites }
        }
        let worker = ChatArchiveWorker(settingsURL: f.root.appendingPathComponent("settings.json"))
        let reopened = ChatController(persistence: worker, credentials: f.credentials, client: f.client, canDispatch: { true }, onFeedback: { _ in })
        defer { reopened.dispose() }
        reopened.activate(.init(id: "robin", name: "robin", description: "", skinRevision: 0))
        try await chatEventually { reopened.conversation?.messages.count == 24 }
        XCTAssertEqual(reopened.conversation?.messages.first?.content, "问2")
        XCTAssertEqual(reopened.conversation?.messages.last?.content, "答13")
        XCTAssertEqual(f.client.count, 13)
    }

    func testRoleSwitchRejectsStaleStreamAndLoad() async throws {
        let f = try fixture()
        await f.persistence.holdNextLoad("robin")
        f.controller.activate(.init(id: "robin", name: "robin", description: "", skinRevision: 0))
        await f.persistence.waitForLoad("robin")
        try await f.open("hutao")
        await f.persistence.releaseLoad("robin")
        f.controller.setDraft("胡桃问题"); f.controller.send()
        try await chatEventually { f.client.count == 1 }
        try await f.open("robin")
        f.client.complete(0, answer: "不能串到知更鸟")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.controller.conversation?.messages.count, 0)
        XCTAssertEqual(f.controller.character?.id, "robin")
        f.controller.setDraft("旧副本问题"); f.controller.send()
        try await chatEventually { f.client.count == 2 }
        try await f.open("robin", revision: 1)
        f.client.complete(1, answer: "不能来自旧副本")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.controller.conversation?.messages.count, 0)
        XCTAssertEqual(f.feedback.lines.count, 0)
    }

    func testPendingPairSurvivesSwitchAndLocalRetryDoesNotRequestAgain() async throws {
        let f = try fixture()
        try await f.open()
        await f.persistence.failNext("append:robin")
        f.controller.setDraft("原问题"); f.controller.send()
        try await chatEventually { f.client.count == 1 }
        f.client.complete(0, answer: "完整但未保存")
        try await chatEventually { f.controller.state == .unsaved }
        XCTAssertEqual(f.controller.unsavedCharacterIDs, ["robin"])
        XCTAssertFalse(f.controller.canSend)
        f.controller.applyProfile(.init(background: "不能应用"))
        XCTAssertEqual(f.controller.conversation?.profile.background, "角色介绍")
        try await f.open("hutao")
        f.controller.setDraft("另一角色可用"); XCTAssertTrue(f.controller.canSend)
        try await f.open("robin")
        XCTAssertEqual(f.controller.partialReply, "完整但未保存")
        XCTAssertEqual(f.controller.draft, "原问题")
        f.controller.retryPendingSave()
        try await chatEventually { f.controller.unsavedCharacterIDs.isEmpty && !f.controller.hasPendingWrites }
        XCTAssertEqual(f.controller.conversation?.messages.count, 2)
        XCTAssertEqual(f.client.count, 1)
        let reads = await f.credentials.reads; XCTAssertEqual(reads, 1)
        XCTAssertTrue(f.feedback.lines.isEmpty)
    }

    func testClearAfterAcceptedAppendCannotResurrectHistory() async throws {
        let f = try fixture()
        try await f.open()
        await f.persistence.holdNextWrite()
        f.controller.setDraft("将清空"); f.controller.send()
        try await chatEventually { f.client.count == 1 }
        f.client.complete(0, answer: "完整回答")
        await f.persistence.waitForOperations(1)
        f.controller.clearHistory()
        await f.persistence.releaseWrite()
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.conversation?.messages.count, 0)
        XCTAssertTrue(f.controller.unsavedCharacterIDs.isEmpty)
        XCTAssertTrue(f.feedback.lines.isEmpty)
        XCTAssertEqual(f.client.count, 1)
    }

    func testCredentialAndPreferencePartialResultsAreReported() async throws {
        let f = try fixture()
        try await f.open()
        f.controller.saveCredential("NEW-TEST")
        await f.controller.waitForPendingWrites()
        XCTAssertNotNil(f.controller.credentialFeedback)
        await f.persistence.failNext("connection")
        f.controller.saveConnection(.init(enabled: true, model: .pro))
        await f.controller.waitForPendingWrites()
        XCTAssertEqual(f.controller.connection.model, .flash)
        XCTAssertNotNil(f.controller.connectionError)
        let key = try await f.credentials.read(); XCTAssertEqual(key, "NEW-TEST")
        XCTAssertEqual(f.client.count, 0)
        await f.credentials.failNextSave()
        f.controller.saveCredential("UNSAVED-TEST")
        await f.controller.waitForPendingWrites()
        XCTAssertNotNil(f.controller.credentialMutationError)
    }

    func testCredentialReadFailureDoesNotRequestAPI() async throws {
        for missing in [false, true] {
            let f = try fixture()
            try await f.open()
            if missing { await f.credentials.setKey(nil) } else { await f.credentials.setReadFailure("已取消钥匙串访问。") }
            f.controller.setDraft("保留输入"); f.controller.send()
            try await chatEventually { f.controller.state == .failed }
            XCTAssertEqual(f.client.count, 0)
            XCTAssertEqual(f.controller.draft, "保留输入")
            XCTAssertNotNil(f.controller.error)
        }
    }
}
