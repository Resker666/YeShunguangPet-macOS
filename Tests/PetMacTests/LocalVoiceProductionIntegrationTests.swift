import AppKit
import XCTest
import PetCore

@MainActor private final class LocalVoiceProductionFixture {
    let chat: ChatControllerFixture
    let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer(), system = ControlledVoiceOutput(), input = ControlledVoiceInput()
    let output: LocalVoiceOutput
    var voice: ChatVoiceController { chat.controller.voice! }
    init(runtime: Bool = true) throws {
        chat = try ChatControllerFixture()
        let config = try LocalVoiceServiceFixtures.configuration(root: chat.root)
        let resolved = try LocalVoiceServiceFixtures.voice(root: chat.root)
        let store = LocalVoiceIndexStore(root: chat.root.appendingPathComponent("LocalVoice"))
        _ = try store.apply(.bind(characterID: "robin", libraryID: resolved.libraryUUID))
        if !runtime { try FileManager.default.removeItem(at: chat.root.appendingPathComponent("LocalVoice/Engine/current.json")) }
        output = LocalVoiceOutput(process: process, player: player, configuration: { config })
        chat.controller.configureVoice(services: .init(input: input, routing: VoiceOutputRouter(system: system, local: output)), now: { .zero })
    }
    func open() async throws {
        try await chat.open()
        chat.controller.updateVoiceEnvironment(.init(surface: .conversation))
        try await chatEventually { self.voice.settings.isLoaded && self.chat.controller.localVoices?.isLoaded == true }
        voice.settings.apply(.init(enabled: true)); await chat.controller.waitForPendingWrites()
    }
    func close() async { process.stopResult = true; process.releaseStop(); _ = await output.stop(); await chat.close() }
}

@MainActor final class LocalVoiceProductionIntegrationTests: XCTestCase {
    func testExitWaitsForInitializingWorkerWhenWriteQueueIsEmpty() async throws {
        let f = try LocalVoiceProductionFixture(); try await f.open()
        f.process.holdStart = true; f.voice.readLatest("初始化中退出")
        try await chatEventually { f.process.starts == 1 }
        XCTAssertFalse(f.chat.controller.hasPendingWrites)
        f.process.holdStop = true; f.chat.controller.beginTermination()
        XCTAssertTrue(f.chat.controller.hasPendingTerminationResources)
        var replied: Bool?
        let finishing = Task { replied = await ChatTerminationCoordinator.finish(chat: f.chat.controller, confirmSave: { _ in true }, resourceDecision: { _ in .cancel }) }
        try await chatEventually { f.process.stops > 0 }
        for _ in 0..<20 { await Task.yield() }; XCTAssertNil(replied)
        f.process.releaseStop(); await finishing.value
        XCTAssertEqual(replied, true); XCTAssertFalse(f.output.hasResources); XCTAssertEqual(f.player.plays, 0)
        await f.close()
    }
    func testFailedStopRetryOrCancelledExitNeverResumes() async throws {
        for retry in [true, false] {
            let f = try LocalVoiceProductionFixture(); try await f.open()
            f.process.holdGeneration = true; f.voice.readLatest("生成中退出")
            try await chatEventually { f.process.generates == 1 }
            f.process.stopResult = false; f.chat.controller.beginTermination()
            var decisions = 0
            let result = await ChatTerminationCoordinator.finish(chat: f.chat.controller, confirmSave: { _ in true }, resourceDecision: { _ in
                decisions += 1
                if retry { f.process.stopResult = true; return .retry }
                return .cancel
            })
            XCTAssertEqual(result, retry); XCTAssertEqual(decisions, 1)
            if !result { f.chat.controller.cancelTermination() }
            XCTAssertFalse(f.voice.hasOutputActivity); XCTAssertEqual(f.process.generates, 1); XCTAssertTrue(f.system.spoken.isEmpty); XCTAssertEqual(f.player.plays, 0)
            await f.close()
        }
    }
    func testQuickFullHandoffPreservesOneWorkerAndActualSource() async throws {
        let f = try LocalVoiceProductionFixture(); try await f.open()
        let pet = try ShortcutFixture(); defer { pet.close() }
        let bar = StatusBarController(session: pet.session, updates: .init(currentVersion: ReleaseVersion(tag: "0.6.0")!, architecture: .arm64, client: NoReleaseRequests()), registry: pet.registry, chat: f.chat.controller, onQuit: {})
        defer { bar.dispose() }
        bar.openQuickChat()
        let local = try XCTUnwrap(f.chat.controller.localVoices)
        local.applyBinding(try XCTUnwrap(local.index.packages.first?.id), expected: try XCTUnwrap(f.chat.controller.character))
        await local.waitForPendingMutations()
        f.voice.readLatest("双窗共用音色")
        try await chatEventually { f.player.plays == 1 }
        let identity = f.voice.actualOutput
        bar.chatPresentation?.present(.full); bar.chatPresentation?.present(.quick)
        XCTAssertEqual(f.process.starts, 1); XCTAssertEqual(f.player.plays, 1); XCTAssertEqual(f.voice.actualOutput, identity)
        XCTAssertEqual(identity?.backend, .local)
        pet.session.setVisible(false); bar.refresh(); XCTAssertTrue(f.voice.isSpeaking)
        XCTAssertEqual(f.input.permissionRequests, 0); XCTAssertTrue(f.system.spoken.isEmpty); XCTAssertEqual(f.chat.client.count, 0)
        await f.close()
    }
    func testMissingRuntimeDoesNotBreakTextOrSystemSpeech() async throws {
        let f = try LocalVoiceProductionFixture(runtime: false); try await f.open()
        f.voice.readLatest("没有引擎时继续使用系统音色")
        try await chatEventually { f.system.spoken.count == 1 }
        XCTAssertEqual(f.process.starts, 0); XCTAssertEqual(f.voice.actualOutput?.backend, .system); XCTAssertNotNil(f.voice.error)
        f.chat.controller.setDraft("文字仍可用"); f.chat.controller.send()
        try await chatEventually { f.chat.client.count == 1 }
        f.chat.client.complete(0, answer: "文字回复")
        try await chatEventually { f.chat.controller.conversation?.messages.count == 2 }
        XCTAssertEqual(f.input.permissionRequests, 0)
        await f.close()
    }
    func testGeneratingControlsOfferStopAndDescribeLocalPhase() async throws {
        let f = try LocalVoiceProductionFixture(); try await f.open()
        f.process.holdGeneration = true; f.voice.readLatest("生成阶段可停止")
        try await chatEventually { f.process.generates == 1 }
        let controls = ChatVoiceControls(controller: f.chat.controller, hasBlockingModal: { false }, hasMarkedInput: { false }, selection: { .init(location: 0, length: 0) }, openSettings: {})
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) } }
        let stop = descendants(controls, NSButton.self).first { $0.title == "停止朗读" }
        XCTAssertNotNil(stop); XCTAssertTrue(stop?.isEnabled == true)
        XCTAssertTrue(descendants(controls, NSTextField.self).contains { $0.stringValue.contains("正在生成本地语音") })
        if let stop { NSApp.sendAction(try XCTUnwrap(stop.action), to: stop.target, from: stop) }
        try await chatEventually { !f.voice.hasOutputActivity }; XCTAssertEqual(f.player.plays, 0)
        await f.close()
    }
    func testFailedLocalIndexSaveIsIncludedInExitRetry() async throws {
        let f = try LocalVoiceProductionFixture(); try await f.open()
        let local = try XCTUnwrap(f.chat.controller.localVoices), role = try XCTUnwrap(f.chat.controller.character)
        await f.chat.persistence.failNext("localVoice")
        local.applyBinding(nil, expected: role); await local.waitForPendingMutations()
        f.chat.controller.beginTermination()
        XCTAssertNotNil(f.chat.controller.terminationSaveError); XCTAssertTrue(f.chat.controller.canRetryTerminationSave)
        let saved = await f.chat.controller.retryAllPendingSaves()
        XCTAssertTrue(saved); XCTAssertNil(local.index.binding(for: role.id)); XCTAssertNil(f.chat.controller.terminationSaveError)
        await f.close()
    }
}
