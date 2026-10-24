import Foundation
import Combine
import XCTest
import PetCore

@MainActor final class ChatVoiceControllerTests: XCTestCase {
    func testRecordingAndFinalDeadlinesDoNotInsertPartial() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.input.starts.count == 1 }
        let token = h.input.starts[0].token
        h.input.emit(token, .partial("尚未完成"))
        XCTAssertEqual(h.snapshot.text, ""); XCTAssertTrue(h.controller.suppressesCompletionAudio)
        h.advance(by: .seconds(45)); XCTAssertEqual(h.input.finishCount, 1)
        XCTAssertTrue(h.insertions.isEmpty)
        h.advance(by: .seconds(5)); XCTAssertFalse(h.controller.blocksChat)
        XCTAssertEqual(h.controller.preview, "尚未完成")
        h.input.emit(token, .final("超时晚回")); XCTAssertTrue(h.insertions.isEmpty)
        h.controller.acceptPreview(); XCTAssertEqual(h.snapshot.text, "尚未完成")
        h.controller.acceptPreview(); XCTAssertEqual(h.insertions.count, 1)
        await h.close()
    }
    func testFinalInsertsOnceAtFrozenSelectionAndNeverSends() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.snapshot = .init(character: h.snapshot.character, revision: 1, text: "甲乙")
        h.controller.beginInput(selection: .init(location: 1, length: 1))
        try await chatEventually { h.input.starts.count == 1 }
        let token = h.input.starts[0].token
        h.input.emit(token, .final("你好")); h.input.emit(token, .final("重复"))
        XCTAssertEqual(h.snapshot.text, "甲你好"); XCTAssertEqual(h.insertions.count, 1)
        XCTAssertEqual(h.insertions.first?.selection, .init(location: 3, length: 0))
        XCTAssertFalse(h.controller.blocksChat)
        await h.close()
    }
    func testLatePermissionAndFailedOutputStopNeverStartCapture() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.input.holdPermissions = true
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.input.permissionRequests == 1 }
        h.setEnvironment(.init(surface: .hidden)); h.input.releasePermissions()
        h.setEnvironment(.init(surface: .conversation)); h.output.stopResult = false
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { !h.controller.blocksChat && h.controller.error != nil }
        XCTAssertTrue(h.input.starts.isEmpty)
        await h.close()
    }
    func testNetworkRequiresExplicitNewRecordingAndDoesNotPersistConsent() async throws {
        let h = try await VoiceControllerHarness.makeEnabled(); h.input.availabilityValue.supportsOnDevice = false
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.controller.canOfferNetwork }
        XCTAssertTrue(h.input.starts.isEmpty)
        h.controller.allowNetworkForThisRecording(selection: .init(location: 0, length: 0))
        try await chatEventually { h.input.starts.count == 1 }
        XCTAssertEqual(h.input.starts[0].mode, .allowNetwork)
        h.controller.cancelInput(); h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.controller.canOfferNetwork }
        XCTAssertEqual(h.input.starts.count, 1)
        await h.close()
    }
    func testDraftABAAndSameIDNewSkinRejectOldFinal() async throws {
        for skinChanges in [false, true] {
            let h = try await VoiceControllerHarness.makeEnabled()
            h.controller.beginInput(selection: .init(location: 0, length: 0))
            try await chatEventually { h.input.starts.count == 1 }
            let token = h.input.starts[0].token, old = h.snapshot
            let role = skinChanges ? ChatCharacter(id: old.character.id, name: old.character.name, description: old.character.description, skinRevision: 1) : old.character
            h.snapshot = .init(character: role, revision: old.revision + 2, text: old.text)
            h.input.emit(token, .final("不能覆盖"))
            XCTAssertTrue(h.insertions.isEmpty); XCTAssertFalse(h.controller.blocksChat)
            h.controller.acceptPreview(); XCTAssertTrue(h.insertions.isEmpty)
            await h.close()
        }
    }
    func testInvalidFinalAndNewRecordingDiscardPreview() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.input.starts.count == 1 }
        h.input.emit(h.input.starts[0].token, .partial("已有预览"))
        h.input.emit(h.input.starts[0].token, .final(String(repeating: "长", count: 2001)))
        XCTAssertTrue(h.insertions.isEmpty); XCTAssertNotNil(h.controller.error)
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.input.starts.count == 2 }
        XCTAssertEqual(h.controller.preview, "")
        h.input.emit(h.input.starts[1].token, .final("")); XCTAssertTrue(h.insertions.isEmpty)
        await h.close()
    }
    func testAutoReadConsumesRevisionsBeforeGatesAndBoundsText() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.setEnvironment(.init(surface: .hidden)); h.controller.didSaveReply(h.reply(2))
        h.setEnvironment(.init(surface: .conversation)); h.controller.didSaveReply(h.reply(2)); h.controller.didSaveReply(h.reply(1))
        h.controller.didSaveReply(h.reply(3, text: String(repeating: "你好。", count: 300)))
        try await chatEventually { h.output.spoken.count == 1 }
        XCTAssertLessThanOrEqual(h.output.spoken[0].text.utf16.count, 600)
        h.controller.didSaveReply(h.reply(3)); XCTAssertEqual(h.output.spoken.count, 1)
        await h.close()
    }
    func testManualReadFallbackAndNoVoiceDoNotChangePreference() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.settings.apply(.init(enabled: true, voiceIdentifier: "missing")); await h.writes.waitForPending()
        h.controller.readLatest(String(repeating: "中", count: 8000))
        try await chatEventually { h.output.spoken.count == 1 }
        XCTAssertEqual(h.output.spoken[0].voiceIdentifier, "test-zh")
        XCTAssertEqual(h.settings.preferences.voiceIdentifier, "missing")
        XCTAssertNotNil(h.controller.actualVoice)
        h.controller.stop(); h.output.voices = []
        h.controller.readLatest("无音色"); XCTAssertNotNil(h.controller.error)
        XCTAssertEqual(h.output.spoken.count, 1)
        h.controller.readLatest(String(repeating: "超", count: 8001)); XCTAssertEqual(h.output.spoken.count, 1)
        await h.close()
    }
    func testQuietAndEveryBlockingEnvironmentCancelWithoutResume() async throws {
        let environments: [VoiceEnvironment] = [.init(surface: .hidden), .init(surface: .other), .init(surface: .conversation, blocked: true), .init(surface: .conversation, sleeping: true), .init(surface: .conversation, terminating: true), .init(surface: .conversation, disposed: true)]
        for environment in environments {
            let h = try await VoiceControllerHarness.makeEnabled()
            h.controller.beginInput(selection: .init(location: 0, length: 0))
            try await chatEventually { h.input.starts.count == 1 }
            let token = h.input.starts[0].token
            h.setEnvironment(environment); h.setEnvironment(.init(surface: .conversation))
            h.input.emit(token, .final("旧回调")); XCTAssertTrue(h.insertions.isEmpty)
            XCTAssertFalse(h.controller.blocksChat)
            await h.close()
        }
        let h = try await VoiceControllerHarness.makeEnabled()
        h.controller.readLatest("读完"); try await chatEventually { h.controller.isSpeaking }
        h.setEnvironment(.init(surface: .conversation, effectiveQuiet: true)); XCTAssertFalse(h.controller.isSpeaking)
        h.controller.readLatest("安静不读"); XCTAssertEqual(h.output.spoken.count, 1)
        h.controller.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { h.input.starts.count == 1 }
        h.controller.readLatest("录音不读"); XCTAssertEqual(h.output.spoken.count, 1)
        await h.close()
    }
    func testLateOutputCallbackAndSynchronousFinalAreFenced() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.controller.readLatest("一"); try await chatEventually { h.output.spoken.count == 1 }
        let first = h.output.spoken[0].token
        h.controller.readLatest("二"); try await chatEventually { h.output.spoken.count == 2 }
        h.output.emit(first, .cancelled); XCTAssertTrue(h.controller.isSpeaking)
        h.input.onStart = { token in h.input.emit(token, .final("同步")) }
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.insertions.count == 1 }
        XCTAssertEqual(h.snapshot.text, "同步"); XCTAssertFalse(h.controller.blocksChat)
        await h.close()
    }
    func testOneConfirmedStopBarrierPrecedesEachNewPlayback() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        h.controller.readLatest("新段")
        try await chatEventually { h.output.spoken.count == 1 }
        XCTAssertEqual(h.output.stops, 1, "An unawaited extra stop could cancel the new playback later")
        await h.close()
    }
    func testPublishedSubscriberCanHideBeforeCaptureStarts() async throws {
        let h = try await VoiceControllerHarness.makeEnabled()
        let observation = h.controller.objectWillChange.sink { [weak h] _ in
            MainActor.assumeIsolated {
                guard let h, h.controller.captureState == .recording else { return }
                h.setEnvironment(.init(surface: .hidden))
            }
        }
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { h.controller.captureState == .idle }
        XCTAssertTrue(h.input.starts.isEmpty); observation.cancel()
        await h.close()
    }
}
