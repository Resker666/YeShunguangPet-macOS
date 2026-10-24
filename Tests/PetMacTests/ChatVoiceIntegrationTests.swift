import Foundation
import XCTest
import PetCore

@MainActor final class ChatVoiceIntegrationTests: XCTestCase {
    private func configure(_ f: ChatControllerFixture) async throws -> (ControlledVoiceInput, ControlledVoiceOutput, ChatVoiceController) {
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
        f.controller.configureVoice(services: .init(input: input, output: output), now: { .zero })
        let voice = try XCTUnwrap(f.controller.voice)
        try await chatEventually { voice.settings.isLoaded }
        voice.settings.apply(.init(enabled: true)); await f.controller.waitForPendingWrites()
        f.controller.updateVoiceEnvironment(.init(surface: .conversation))
        return (input, output, voice)
    }
    func testOnlyFirstSuccessfulModelSaveCanReadAloud() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let (_, output, _) = try await configure(f)
        await f.persistence.holdNextWrite()
        f.controller.setDraft("你好"); f.controller.send()
        try await chatEventually { f.client.count == 1 }; f.client.complete(0, answer: "已存后读")
        await f.persistence.waitForOperations(2)
        XCTAssertTrue(output.spoken.isEmpty)
        await f.persistence.releaseWrite(); await f.controller.waitForPendingWrites()
        try await chatEventually { output.spoken.count == 1 }
        XCTAssertEqual(output.spoken[0].text, "已存后读")
        await f.close()
    }
    func testLocalRetryDoesNotReadOrRequestAgain() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let (_, output, _) = try await configure(f)
        await f.persistence.failNext("append:robin")
        f.controller.setDraft("保存失败"); f.controller.send()
        try await chatEventually { f.client.count == 1 }; f.client.complete(0, answer: "完整回复")
        try await chatEventually { f.controller.state == .unsaved }
        let reads = await f.credentials.reads
        XCTAssertTrue(output.spoken.isEmpty)
        f.controller.retryPendingSave(); await f.controller.waitForPendingWrites()
        XCTAssertTrue(output.spoken.isEmpty); XCTAssertEqual(f.client.count, 1)
        let readsAfter = await f.credentials.reads; XCTAssertEqual(reads, readsAfter)
        await f.close()
    }
    func testVoiceFinalChangesDraftWithoutSendingOrWritingHistory() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let (input, _, voice) = try await configure(f)
        f.controller.setDraft("甲乙")
        voice.beginInput(selection: .init(location: 1, length: 1))
        try await chatEventually { input.starts.count == 1 }
        XCTAssertFalse(f.controller.canSend); XCTAssertFalse(f.controller.canEditMemories)
        input.emit(input.starts[0].token, .partial("你好")); XCTAssertEqual(f.controller.draft, "甲乙")
        input.emit(input.starts[0].token, .final("你好"))
        XCTAssertEqual(f.controller.draft, "甲你好"); XCTAssertEqual(f.client.count, 0)
        XCTAssertTrue(f.controller.conversation?.messages.isEmpty == true)
        XCTAssertEqual(f.controller.takeVoiceSelection(), .init(location: 3, length: 0))
        XCTAssertNil(f.controller.takeVoiceSelection())
        let operations = await f.persistence.operations; XCTAssertEqual(operations, ["voicePreferences"])
        await f.close()
    }
    func testDraftABAAndSameIDNewSkinCannotApplyOldVoice() async throws {
        for skin in [false, true] {
            let f = try ChatControllerFixture(); try await f.open()
            let (input, _, voice) = try await configure(f)
            voice.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { input.starts.count == 1 }
            let token = input.starts[0].token
            if skin { try await f.open(revision: 1) }
            else { f.controller.setDraft("改变"); f.controller.setDraft("") }
            input.emit(token, .final("旧识别")); XCTAssertEqual(f.controller.draft, ""); XCTAssertNil(f.controller.takeVoiceSelection())
            await f.close()
        }
    }
    func testParentLifecycleOverridesStaleExternalEnvironmentDuringPermissions() async throws {
        for action in 0..<4 {
            let f = try ChatControllerFixture(); try await f.open()
            let (input, _, voice) = try await configure(f); input.holdPermissions = true
            voice.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { input.permissionRequests == 1 }
            switch action {
            case 0: f.controller.stop()
            case 1: f.controller.windowClosed()
            case 2: f.controller.setSleeping(true)
            default: f.controller.beginTermination()
            }
            f.controller.updateVoiceEnvironment(.init(surface: .conversation)); input.releasePermissions()
            f.controller.setSleeping(false); f.controller.cancelTermination()
            XCTAssertFalse(voice.blocksChat); XCTAssertTrue(input.starts.isEmpty)
            await f.close()
        }
    }
    func testUnconfirmedActionCannotStartVoiceOrBeConfirmedByVoice() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let (input, output, voice) = try await configure(f)
        f.controller.setDraft("开启安静"); f.controller.send(); try await chatEventually { f.client.count == 1 }
        f.client.propose(0, action: .setQuiet(enabled: true))
        try await chatEventually { f.controller.pendingAction != nil }
        voice.beginInput(selection: .init(location: 0, length: 0))
        XCTAssertFalse(voice.blocksChat); XCTAssertTrue(input.starts.isEmpty); XCTAssertTrue(output.spoken.isEmpty)
        XCTAssertTrue(f.actions.executions.isEmpty)
        await f.close()
    }
    func testUnsavedVoiceParticipatesInExitRetryWithoutReenablingOrAudio() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let (input, output, voice) = try await configure(f)
        await f.persistence.failNext("voicePreferences"); voice.settings.disable()
        await f.controller.waitForPendingWrites()
        XCTAssertNotNil(f.controller.terminationSaveError); XCTAssertTrue(f.controller.canRetryTerminationSave)
        f.controller.beginTermination()
        let saved = await f.controller.retryAllPendingSaves(); XCTAssertTrue(saved)
        XCTAssertNil(f.controller.terminationSaveError); XCTAssertFalse(voice.settings.enabledForSession)
        f.controller.cancelTermination()
        XCTAssertTrue(input.starts.isEmpty); XCTAssertTrue(output.spoken.isEmpty)
        await f.close()
    }
    func testCaptureBlocksStaleConnectionAndCredentialCommands() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        let (input, _, voice) = try await configure(f)
        voice.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { input.starts.count == 1 }
        f.controller.saveConnection(.init(enabled: true)); f.controller.resetConnectionArchive()
        f.controller.saveCredential("NEW-TEST-KEY"); await f.controller.waitForPendingWrites()
        f.controller.removeCredential(); await f.controller.waitForPendingWrites()
        let key = try await f.credentials.read(); XCTAssertEqual(key, "TEST-ONLY")
        let operations = await f.persistence.operations; XCTAssertEqual(operations, ["voicePreferences"])
        XCTAssertTrue(voice.blocksChat)
        await f.close()
    }
    func testBrokenVoiceFileDoesNotFailTextChatAndConfigureIsOnce() async throws {
        let f = try ChatControllerFixture(); try await f.open()
        try Data("bad voice".utf8).write(to: f.root.appendingPathComponent("AI/voice.json"))
        f.controller.configureVoice(services: .init(input: ControlledVoiceInput(), output: ControlledVoiceOutput()), now: { .zero })
        let first = try XCTUnwrap(f.controller.voice)
        try await chatEventually { first.settings.isLoaded }
        XCTAssertNotNil(first.settings.protection); XCTAssertNil(f.controller.error)
        f.controller.configureVoice(services: .init(input: ControlledVoiceInput(), output: ControlledVoiceOutput()), now: { .zero })
        XCTAssertTrue(first === f.controller.voice)
        try await f.send("文字继续", answer: "正常", index: 0)
        XCTAssertEqual(f.controller.conversation?.messages.count, 2)
        await f.close()
    }
}
