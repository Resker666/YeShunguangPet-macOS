import AppKit
import XCTest
import PetCore

@MainActor final class ChatLifecycleTests: XCTestCase {
    private func fixture() throws -> ChatControllerFixture {
        let value = try ChatControllerFixture()
        addTeardownBlock { await value.close() }
        return value
    }
    func testBackgroundSleepAndCancelledTerminationNeverResumeRequest() async throws {
        for duringRead in [true, false] {
            let f = try fixture(); try await f.open()
            if duringRead { await f.credentials.holdNextRead() }
            f.controller.setDraft("正在请求"); f.controller.send()
            if duringRead { await f.credentials.waitForReads(1) }
            else { try await chatEventually { f.client.count == 1 } }
            let center = NSWorkspace.shared.notificationCenter
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { center.post(name: NSWorkspace.willSleepNotification, object: nil); continuation.resume() }
            }
            try await chatEventually { f.controller.sleeping }
            f.controller.beginTermination(); f.controller.cancelTermination()
            f.controller.setSleeping(false)
            await f.credentials.releaseRead()
            if !duringRead { f.client.complete(0, answer: "过期回复") }
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.client.count, duringRead ? 0 : 1)
            XCTAssertEqual(f.controller.conversation?.messages.count, 0)
            XCTAssertEqual(f.controller.draft, "正在请求")
        }
    }
    func testCloseAndExitPreserveAllPendingRoles() async throws {
        let f = try fixture(); try await f.open()
        for (index, id) in ["robin", "hutao"].enumerated() {
            try await f.open(id)
            await f.persistence.failNext("append:" + id)
            f.controller.setDraft("问" + id); f.controller.send()
            try await chatEventually { f.client.count == index + 1 }
            f.client.complete(index, answer: "答" + id)
            try await chatEventually { f.controller.state == .unsaved }
            f.controller.windowClosed()
        }
        XCTAssertEqual(f.controller.unsavedCharacterIDs, ["hutao", "robin"])
        f.controller.beginTermination()
        let saved = await f.controller.retryAllPendingSaves()
        XCTAssertTrue(saved)
        XCTAssertTrue(f.controller.unsavedCharacterIDs.isEmpty)
        f.controller.cancelTermination()
        XCTAssertEqual(f.client.count, 2)
        XCTAssertTrue(f.feedback.lines.isEmpty)
    }
    func testTerminationWaitsForAcceptedWrite() async throws {
        let f = try fixture(); try await f.open()
        await f.persistence.holdNextWrite()
        f.controller.setDraft("已完成"); f.controller.send()
        try await chatEventually { f.client.count == 1 }
        f.client.complete(0, answer: "待落盘")
        await f.persistence.waitForOperations(1)
        f.controller.beginTermination()
        let flag = ChatTestFlag()
        let waiting = Task { @MainActor in await f.controller.waitForPendingWrites(); flag.value = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(flag.value)
        await f.persistence.releaseWrite(); await waiting.value
        XCTAssertTrue(flag.value)
        XCTAssertEqual(f.controller.conversation?.messages.count, 2)
        XCTAssertTrue(f.feedback.lines.isEmpty)
        f.controller.cancelTermination()
        XCTAssertEqual(f.client.count, 1)
    }
}
