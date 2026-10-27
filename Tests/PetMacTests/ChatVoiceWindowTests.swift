import AppKit
import XCTest
import PetCore

@MainActor final class ChatVoiceWindowTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) } }
    private func press(_ button: NSButton) throws { NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button) }
    private func configure(_ f: ChatControllerFixture, enabled: Bool = true) async throws -> (ControlledVoiceInput, ControlledVoiceOutput, ChatVoiceController) {
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
        f.controller.configureVoice(services: .init(input: input, output: output), now: { .zero })
        let voice = try XCTUnwrap(f.controller.voice); try await chatEventually { voice.settings.isLoaded }
        if enabled { voice.settings.apply(.init(enabled: true)); await f.controller.waitForPendingWrites() }
        return (input, output, voice)
    }
    func testVoiceSettingsNoAutomaticServiceAndAllFivePages() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        let (input, output, _) = try await configure(f, enabled: false)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present()
        let settings = try XCTUnwrap(descendants(full.pageScroll, NSButton.self).first { $0.title == "语音设置…" })
        try press(settings); XCTAssertEqual(full.pages.selectedSegment, 4)
        XCTAssertEqual(full.pages.segmentCount, 5)
        for i in 0..<5 { full.selectPage(i); XCTAssertEqual(full.pages.selectedSegment, i) }
        XCTAssertEqual(input.permissionRequests, 0); XCTAssertTrue(input.starts.isEmpty); XCTAssertTrue(output.spoken.isEmpty)
        await f.close()
    }
    func testMarkedInputCannotRecordAndCaptureFreezesComposer() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        let (input, _, voice) = try await configure(f)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present()
        let button = try XCTUnwrap(descendants(full.pageScroll, NSButton.self).first { $0.title == "开始说话" })
        full.composer.setMarkedText("输入中", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        full.render(); try press(button); XCTAssertTrue(input.starts.isEmpty)
        full.composer.unmarkText(); full.render(); try press(button)
        try await chatEventually { input.starts.count == 1 }; full.render()
        XCTAssertFalse(full.composer.isEditable)
        let finish = try XCTUnwrap(descendants(full.pageScroll, NSButton.self).first { $0.title == "结束识别" })
        let cancel = try XCTUnwrap(descendants(full.pageScroll, NSButton.self).first { $0.title == "取消录音" })
        XCTAssertFalse(finish.isHidden); XCTAssertTrue(cancel.isEnabled)
        try press(finish); XCTAssertEqual(voice.captureState, .finishing)
        full.selectPage(1); XCTAssertFalse(voice.blocksChat)
        input.emit(input.starts[0].token, .final("晚回")); XCTAssertFalse(f.controller.draft.contains("晚回"))
        await f.close()
    }
    func testRealWindowsPreserveCaptureAcrossCachedOtherPageAndSelection() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); try await f.open()
        let (input, output, voice) = try await configure(f)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in })
        let quick = QuickChatWindowController(controller: f.controller, session: pet.session, onExpand: {}, canDispatch: { true })
        let coordinator = ChatPresentationCoordinator(controller: f.controller, onPresented: { _ in }); defer { coordinator.dispose() }
        coordinator.register(full, for: .full); coordinator.register(quick, for: .quick)
        coordinator.present(.full); full.selectPage(4); coordinator.present(.quick)
        voice.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { input.starts.count == 1 }
        let stops = output.stops; coordinator.present(.full)
        XCTAssertTrue(voice.blocksChat); XCTAssertEqual(full.pages.selectedSegment, 0); XCTAssertEqual(output.stops, stops)
        voice.finishInput(); coordinator.present(.quick); XCTAssertEqual(voice.captureState, .finishing)
        input.emit(input.starts[0].token, .final("识别文字")); coordinator.present(.full); full.render()
        XCTAssertEqual(full.composer.string, "识别文字"); XCTAssertEqual(full.inputSelection, .init(location: 4, length: 0))
        voice.readLatest("已保存回复"); try await chatEventually { voice.isSpeaking }
        coordinator.present(.quick); XCTAssertTrue(voice.isSpeaking); XCTAssertEqual(output.spoken.count, 1)
        quick.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        // A notification alone is not a physical minimization; simulate app hide explicitly for the logical boundary.
        f.controller.updateVoiceEnvironment(.init(surface: .hidden)); XCTAssertFalse(voice.isSpeaking)
        await f.close()
    }
    func testLeavingConversationStopsReadButVoicePageAllowsExplicitPreview() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        let (_, output, voice) = try await configure(f)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present(); voice.readLatest("当前回复"); try await chatEventually { voice.isSpeaking }
        full.selectPage(4); XCTAssertFalse(voice.isSpeaking)
        voice.previewVoice(); try await chatEventually { output.spoken.count == 2 }
        XCTAssertTrue(voice.isSpeaking)
        full.selectPage(3); XCTAssertFalse(voice.isSpeaking)
        await f.close()
    }
    func testDisabledVoiceRetainsFailedStopRetryControl() async throws {
        _ = NSApplication.shared
        let f = try ChatControllerFixture(); try await f.open()
        let (_, output, voice) = try await configure(f)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in }); defer { full.dispose() }
        full.present(); voice.readLatest("当前朗读"); try await chatEventually { voice.isSpeaking }
        output.stopResult = false; let count = output.stops
        voice.settings.disable(); await f.controller.waitForPendingWrites(); try await chatEventually { voice.outputStopFailed && !voice.isStoppingOutput }
        XCTAssertEqual(output.stops, count + 1)
        full.render()
        let retry = try XCTUnwrap(descendants(full.pageScroll, NSButton.self).first { $0.title == "重试停止朗读" })
        XCTAssertFalse(retry.isHidden); XCTAssertTrue(retry.isEnabled)
        output.stopResult = true; try press(retry); try await chatEventually { !voice.isStoppingOutput && !voice.outputStopFailed }
        XCTAssertEqual(output.stops, count + 2)
        full.render(); XCTAssertFalse(voice.settings.enabledForSession); XCTAssertNil(voice.error)
        XCTAssertEqual(output.spoken.count, 1)
        await f.close()
    }
    func testLongPreviewAndNetworkChoiceScrollAtBothMinimumSizes() async throws {
        let pet = try ShortcutFixture(); defer { pet.close() }
        let f = try ChatControllerFixture(); try await f.open()
        let (input, _, voice) = try await configure(f)
        let full = ChatWindowController(controller: f.controller, onPresentationChange: { _ in })
        let quick = QuickChatWindowController(controller: f.controller, session: pet.session, onExpand: {}, canDispatch: { true })
        let coordinator = ChatPresentationCoordinator(controller: f.controller, onPresented: { _ in }); defer { coordinator.dispose() }
        coordinator.register(full, for: .full); coordinator.register(quick, for: .quick); coordinator.present(.quick)
        voice.beginInput(selection: .init(location: 0, length: 0)); try await chatEventually { input.starts.count == 1 }
        input.emit(input.starts[0].token, .partial(String(repeating: "长识别预览。", count: 250)))
        input.emit(input.starts[0].token, .failed(.onDeviceUnavailable))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            quick.window?.appearance = NSAppearance(named: name); quick.window?.setContentSize(.init(width: 320, height: 240)); quick.render()
            XCTAssertGreaterThan(quick.bodyScroll.documentView?.frame.height ?? 0, quick.bodyScroll.contentSize.height)
            let online = try XCTUnwrap(descendants(quick.bodyScroll, NSButton.self).first { $0.title == "允许本次在线识别" })
            XCTAssertFalse(online.isHidden)
            coordinator.present(.full); full.window?.appearance = NSAppearance(named: name); full.window?.setContentSize(.init(width: 440, height: 420)); full.render()
            XCTAssertTrue(full.pageScroll.hasVerticalScroller); XCTAssertGreaterThan(full.pageScroll.documentView?.frame.height ?? 0, full.pageScroll.contentSize.height)
            coordinator.present(.quick)
        }
        XCTAssertEqual(input.starts.count, 1)
        await f.close()
    }
}
