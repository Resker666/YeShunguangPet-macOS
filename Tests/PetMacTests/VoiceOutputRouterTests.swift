import Foundation
import Combine
import XCTest
import PetCore

@MainActor private final class RoutedVoiceFixture {
    let root: URL, configuration: LocalVoiceEngineConfiguration, voice: ResolvedLocalVoice
    let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer(), system = ControlledVoiceOutput()
    let local: LocalVoiceOutput
    let router: VoiceOutputRouter
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configuration = try LocalVoiceServiceFixtures.configuration(root: root)
        voice = try LocalVoiceServiceFixtures.voice(root: root)
        let configuration = configuration
        local = LocalVoiceOutput(process: process, player: player, configuration: { configuration })
        router = VoiceOutputRouter(system: system, local: local)
    }
    func request(_ text: String = "测试本地回复", rate: Double = 0.5, isValid: @escaping @MainActor () -> Bool = { true }) -> RoutedVoiceRequest {
        .init(token: UUID(), text: text, rate: rate, preferredSystemVoiceID: "missing", selection: .local(voice), isValid: isValid)
    }
    func close() async { _ = await router.stop(); try? FileManager.default.removeItem(at: root) }
}

@MainActor final class VoiceOutputRouterTests: XCTestCase {
    func testCancelledSelectionNeverFallsBackToSystem() async throws {
        let f = try RoutedVoiceFixture()
        var terminal = false
        try f.router.speak(.init(token: UUID(), text: "已取消", rate: 0.5, preferredSystemVoiceID: nil, selection: .unavailable(.cancelled))) { _, event in
            if event == .cancelled { terminal = true }
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(terminal); XCTAssertTrue(f.system.spoken.isEmpty)
        await f.close()
    }
    func testLocalOutputStartsWithNoInstalledAppleVoice() async throws {
        let f = try RoutedVoiceFixture(), h = try VoiceControllerHarness(); f.system.voices = []
        h.routing = f.router; h.selection = .local(f.voice)
        try await chatEventually { h.settings.isLoaded }
        h.settings.apply(.init(enabled: true)); await h.writes.waitForPending(); h.controller.updateEnvironment(h.environment)
        h.controller.readLatest(String(repeating: "中", count: 600))
        try await chatEventually { f.player.plays == 1 }
        XCTAssertTrue(f.system.spoken.isEmpty)
        XCTAssertTrue(h.controller.availableVoices.isEmpty)
        XCTAssertEqual(h.controller.actualOutput?.libraryID, f.voice.libraryUUID)
        await h.close(); await f.close()
    }
    func testPrePlaybackFailureFallsBackOnceAfterConfirmedStop() async throws {
        let f = try RoutedVoiceFixture(); f.process.outputData = Data(); f.process.holdStop = true
        let prepared = await f.router.prepare(for: .local(f.voice)); XCTAssertTrue(prepared)
        var notices = 0
        try f.router.speak(f.request()) { _, event in if case .notice = event { notices += 1 } }
        try await chatEventually { f.process.stops == 1 }
        XCTAssertTrue(f.system.spoken.isEmpty)
        f.process.releaseStop()
        try await chatEventually { f.system.spoken.count == 1 }
        XCTAssertEqual(notices, 1)
        f.system.emit(f.system.spoken[0].token, .failed)
        XCTAssertEqual(f.system.spoken.count, 1)
        await f.close()
    }
    func testCancelOrPlaybackFailureNeverFallsBack() async throws {
        for cancel in [true, false] {
            let f = try RoutedVoiceFixture()
            let prepared = await f.router.prepare(for: .local(f.voice)); XCTAssertTrue(prepared)
            try f.router.speak(f.request()) { _, _ in }
            try await chatEventually { f.player.plays == 1 }
            if cancel { _ = await f.router.stop() } else { f.player.fail() }
            await Task.yield()
            XCTAssertTrue(f.system.spoken.isEmpty)
            await f.close()
        }
    }
    func testSameIDNewSkinOrSynchronousHideFencesFallback() async throws {
        for synchronousHide in [false, true] {
            let f = try RoutedVoiceFixture(), h = try VoiceControllerHarness()
            f.process.outputData = Data(); f.process.holdStop = !synchronousHide
            h.routing = f.router; h.selection = .local(f.voice)
            try await chatEventually { h.settings.isLoaded }
            h.settings.apply(.init(enabled: true)); await h.writes.waitForPending(); h.controller.updateEnvironment(h.environment)
            let observation = h.controller.objectWillChange.sink { [weak h] _ in
                MainActor.assumeIsolated {
                    guard synchronousHide, let h, h.controller.error?.contains("系统音色") == true else { return }
                    h.setEnvironment(.init(surface: .hidden))
                }
            }
            h.controller.readLatest("新回复")
            if !synchronousHide {
                try await chatEventually { f.process.stops == 1 }
                let old = h.snapshot.character
                h.snapshot = .init(character: .init(id: old.id, name: old.name, description: old.description, skinRevision: old.skinRevision + 1), revision: 1, text: "")
                h.controller.updateEnvironment(h.environment)
                f.process.releaseStop()
            }
            try await chatEventually { !h.controller.hasOutputActivity }
            XCTAssertTrue(f.system.spoken.isEmpty)
            observation.cancel(); await h.close(); await f.close()
        }
    }
    func testManualLongLocalReplyUsesSystemWithoutTruncation() async throws {
        for count in [601, 8000] {
            let f = try RoutedVoiceFixture(), text = String(repeating: "中", count: count)
            var notices = [String]()
            try f.router.speak(f.request(text)) { _, event in if case .notice(let notice) = event { notices.append(notice) } }
            try await chatEventually { f.system.spoken.count == 1 }
            XCTAssertEqual(f.system.spoken[0].text, text); XCTAssertEqual(f.process.starts, 0)
            XCTAssertEqual(notices.count, 1)
            await f.close()
        }
        let f = try RoutedVoiceFixture()
        XCTAssertThrowsError(try f.router.speak(f.request(String(repeating: "中", count: 8001))) { _, _ in })
        XCTAssertTrue(f.system.spoken.isEmpty); XCTAssertEqual(f.process.starts, 0)
        await f.close()
    }
    func testFailedCleanupPreventsFallbackAndRetryNeverReplays() async throws {
        let f = try RoutedVoiceFixture(); f.process.outputData = Data(); f.process.stopResult = false
        var failure: LocalVoiceIssue?
        try f.router.speak(f.request()) { _, event in if case .failed(let issue) = event { failure = issue } }
        try await chatEventually { failure != nil }
        XCTAssertEqual(failure, .stopping); XCTAssertTrue(f.system.spoken.isEmpty)
        f.process.stopResult = true
        let result = await f.router.stop(); XCTAssertTrue(result)
        XCTAssertTrue(f.system.spoken.isEmpty)
        await f.close()
    }
    func testSynchronousNoticeInvalidationPreventsSystemStart() async throws {
        let f = try RoutedVoiceFixture(); f.process.outputData = Data()
        var valid = true, noticed = false
        try f.router.speak(f.request(isValid: { valid })) { _, event in
            if case .notice = event { noticed = true; valid = false }
        }
        try await chatEventually { noticed }
        XCTAssertTrue(f.system.spoken.isEmpty)
        await f.close()
    }
    func testIdleWorkerIsStoppedWhenSameRoleSkinRevisionChanges() async throws {
        let f = try RoutedVoiceFixture(), h = try VoiceControllerHarness()
        h.routing = f.router; h.selection = .local(f.voice)
        try await chatEventually { h.settings.isLoaded }
        h.settings.apply(.init(enabled: true)); await h.writes.waitForPending(); h.controller.updateEnvironment(h.environment)
        h.controller.readLatest("第一句")
        try await chatEventually { f.player.plays == 1 }; f.player.finish(); try await chatEventually { !h.controller.hasOutputActivity }
        XCTAssertFalse(h.controller.hasOutputActivity); XCTAssertTrue(h.controller.hasPendingResources)
        let old = h.snapshot.character
        h.snapshot = .init(character: .init(id: old.id, name: old.name, description: old.description, skinRevision: 2), revision: 1, text: "")
        h.controller.updateEnvironment(h.environment)
        try await chatEventually { f.process.stops == 1 }
        let confirmed = await h.controller.stopAndWait(); XCTAssertTrue(confirmed)
        XCTAssertFalse(h.controller.hasPendingResources)
        await h.close(); await f.close()
    }
    func testNewReadReusesIdleWorkerButRecordingWaitsForConfirmedFullStop() async throws {
        let f = try RoutedVoiceFixture(), h = try VoiceControllerHarness()
        h.routing = f.router; h.selection = .local(f.voice)
        try await chatEventually { h.settings.isLoaded }
        h.settings.apply(.init(enabled: true)); await h.writes.waitForPending(); h.controller.updateEnvironment(h.environment)
        h.controller.readLatest("第一句"); try await chatEventually { f.player.plays == 1 }; f.player.finish(); try await chatEventually { !h.controller.hasOutputActivity }
        h.controller.readLatest("第二句"); try await chatEventually { f.player.plays == 2 }; f.player.finish(); try await chatEventually { !h.controller.hasOutputActivity }
        XCTAssertEqual(f.process.starts, 1); XCTAssertEqual(f.process.stops, 0)
        XCTAssertEqual(f.process.speeds, [1, 1])
        f.process.stopResult = false
        h.controller.beginInput(selection: .init(location: 0, length: 0))
        try await chatEventually { !h.controller.blocksChat && h.controller.error != nil }
        XCTAssertEqual(h.input.permissionRequests, 0); XCTAssertTrue(h.input.starts.isEmpty)
        f.process.stopResult = true
        let confirmed = await h.controller.stopAndWait(); XCTAssertTrue(confirmed)
        XCTAssertEqual(f.process.generates, 2)
        await h.close(); await f.close()
    }
    func testRateMappingAndMissingSystemFallbackNeverChangeSavedPreference() async throws {
        for (rate, factor) in [(0.35, 0.7), (0.5, 1), (0.65, 1.3)] {
            let f = try RoutedVoiceFixture()
            try f.router.speak(f.request(rate: rate)) { _, _ in }
            try await chatEventually { f.player.plays == 1 }
            XCTAssertEqual(f.process.speeds, [factor])
            await f.close()
        }
        let f = try RoutedVoiceFixture(); f.system.voices = []; f.process.outputData = Data()
        var failure: LocalVoiceIssue?
        try f.router.speak(f.request()) { _, event in if case .failed(let value) = event { failure = value } }
        try await chatEventually { failure != nil }
        XCTAssertEqual(failure, .systemUnavailable); XCTAssertTrue(f.system.spoken.isEmpty)
        await f.close()
    }
    func testFallbackLeavesSavedVoicePreferenceAndLibraryBytesUnchanged() async throws {
        let f = try RoutedVoiceFixture(), h = try VoiceControllerHarness()
        f.process.outputData = Data(); h.routing = f.router; h.selection = .local(f.voice)
        try await chatEventually { h.settings.isLoaded }
        h.settings.apply(.init(enabled: true, voiceIdentifier: "missing", rate: 0.35)); await h.writes.waitForPending()
        h.controller.updateEnvironment(h.environment)
        let preferenceURL = h.root.appendingPathComponent("AI/voice.json"), indexURL = f.root.appendingPathComponent("LocalVoice/index.json")
        let preference = try Data(contentsOf: preferenceURL), index = try Data(contentsOf: indexURL)
        h.controller.readLatest("新测试文字")
        try await chatEventually { f.system.spoken.count == 1 }
        XCTAssertEqual(try Data(contentsOf: preferenceURL), preference)
        XCTAssertEqual(try Data(contentsOf: indexURL), index)
        XCTAssertEqual(h.settings.preferences.voiceIdentifier, "missing")
        await h.close(); await f.close()
    }
}
