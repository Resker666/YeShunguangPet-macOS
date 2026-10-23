import AppKit
import XCTest
import PetCore

@MainActor private final class ActionInput { var time = Duration.zero; var failWrites = false; var modal = false; var savedBeforeStart = false }
@MainActor final class ChatActionBridgeTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL, session: PetSession, focus: FocusController, bridge: FocusChatActionBridge, input: ActionInput
        func close() { bridge.dispose(); focus.dispose(); session.prepareToExit(); try? FileManager.default.removeItem(at: directory) }
    }
    private func fixture(protected: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), input = ActionInput()
        let manifest = try SkinFixtures.writePackage(in: dir.appendingPathComponent("skin"))
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"), write: { data, url in
            if input.failWrites { throw SkinError("injected write failure") }
            input.savedBeforeStart = true; try data.write(to: url, options: .atomic)
        })
        try store.save(.init(placement: nil, preferences: .init(lookAtMouse: false, focusMinutes: 1, breakMinutes: 7)))
        if protected { try Data("broken".utf8).write(to: store.url) }
        let session = PetSession(skin: try SkinLoader.load(manifestURL: manifest), now: { input.time }, settings: store, screens: { [.init(id: "test", visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), isPrimary: true)] })
        session.start()
        let focus = FocusController(session: session, playCompletionSound: {})
        focus.canPlayCompletionSound = { !input.modal }
        let bridge = FocusChatActionBridge(session: session, focus: focus, canDispatch: { !input.modal })
        return .init(directory: dir, session: session, focus: focus, bridge: bridge, input: input)
    }
    private func receipt(_ result: ChatActionExecutionResult, file: StaticString = #filePath, line: UInt = #line) throws -> ChatActionReceipt {
        guard case .finished(let value) = result else { XCTFail("Expected actual receipt", file: file, line: line); throw SkinError("missing receipt") }
        return value
    }
    func testStartPersistsDurationBeforeTimerAndFailureDoesNotStart() throws {
        for minutes in [1, 25, 120] {
            let f = try fixture(); defer { f.close() }
            f.input.savedBeforeStart = false
            f.focus.onChange = { if f.focus.status == .running { XCTAssertTrue(f.input.savedBeforeStart) } }
            let result = try receipt(f.bridge.execute(.startFocus(minutes: minutes), expected: f.bridge.snapshot()))
            XCTAssertEqual(result.outcome, .applied); XCTAssertEqual(f.focus.status, .running)
            XCTAssertEqual(f.focus.remainingSeconds, minutes * 60)
            guard case .loaded(let settings) = f.session.settings.load() else { return XCTFail("saved config missing") }
            XCTAssertEqual(settings.preferences.focusMinutes, minutes); XCTAssertEqual(settings.preferences.breakMinutes, 7)
        }
        for protected in [false, true] {
            let f = try fixture(protected: protected); defer { f.close() }
            let bytes = try Data(contentsOf: f.session.settings.url); f.input.failWrites = true
            XCTAssertEqual(try receipt(f.bridge.execute(.startFocus(minutes: 25), expected: f.bridge.snapshot())).outcome, .failed)
            XCTAssertEqual(f.focus.status, .ready); XCTAssertEqual(try Data(contentsOf: f.session.settings.url), bytes)
        }
    }
    func testPauseResumeRejectCompletedAndRest() throws {
        let f = try fixture(); defer { f.close() }
        _ = f.bridge.execute(.startFocus(minutes: 1), expected: f.bridge.snapshot())
        XCTAssertEqual(try receipt(f.bridge.execute(.pauseFocus, expected: f.bridge.snapshot())).outcome, .applied)
        let paused = f.bridge.snapshot()
        XCTAssertEqual(try receipt(f.bridge.execute(.resumeFocus, expected: paused)).outcome, .applied)
        f.input.time = .seconds(60)
        if case .expired = f.bridge.execute(.pauseFocus, expected: paused) {} else { XCTFail("expired action executed") }
        XCTAssertEqual(f.focus.status, .completed); XCTAssertEqual(f.focus.phase, .focus)
        XCTAssertEqual(try receipt(f.bridge.execute(.resumeFocus, expected: f.bridge.snapshot())).outcome, .failed)
        XCTAssertEqual(f.focus.phase, .focus)
        f.focus.startOrResume()
        for action in [ChatAction.pauseFocus, .resumeFocus] {
            XCTAssertEqual(try receipt(f.bridge.execute(action, expected: f.bridge.snapshot())).outcome, .failed)
        }
        XCTAssertEqual(f.focus.phase, .rest); XCTAssertEqual(f.focus.status, .running)
    }
    func testStampRejectsABAButNotOneSecondTick() throws {
        let f = try fixture(); defer { f.close() }; f.focus.startOrResume()
        let running = f.bridge.snapshot(); f.input.time = .seconds(1)
        XCTAssertEqual(running.commandStamp, f.bridge.snapshot().commandStamp)
        f.focus.pause(); f.focus.startOrResume()
        XCTAssertNotEqual(running.commandStamp, f.bridge.snapshot().commandStamp)
        if case .expired = f.bridge.execute(.pauseFocus, expected: running) {} else { XCTFail("ABA accepted") }
        let quiet = f.bridge.snapshot(); f.session.setQuiet(true); f.session.setQuiet(false)
        XCTAssertNotEqual(quiet.commandStamp, f.bridge.snapshot().commandStamp)
        f.focus.reset(); let ready = f.bridge.snapshot()
        try f.focus.applyDurations(focusMinutes: 25, breakMinutes: 7); try f.focus.applyDurations(focusMinutes: 1, breakMinutes: 7)
        XCTAssertNotEqual(ready.commandStamp, f.bridge.snapshot().commandStamp)
        f.focus.startOrResume(); let inactive = f.bridge.snapshot()
        try f.session.saveFocusDurations(focusMinutes: 1, breakMinutes: 8); f.focus.refreshConfiguration()
        XCTAssertGreaterThan(f.bridge.snapshot().focusRevision, inactive.focusRevision)
    }
    func testQuietNoopKeepsFocusQuietAndObservers() async throws {
        let f = try fixture(); defer { f.close() }
        let menus = FocusMenus(focus: f.focus, canDispatch: { true }, onSettings: {}); defer { menus.dispose() }
        let original = f.focus.onChange; var notifications = 0
        f.focus.onChange = { notifications += 1; original?() }
        let changed = expectation(description: "independent bridge observes focus revision")
        f.bridge.onChange = { changed.fulfill() }; changed.assertForOverFulfill = false
        f.focus.startOrResume()
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertTrue(menus.menus.allSatisfy { $0.items.contains { $0.title.contains("暂停专注") } })
        f.session.setQuiet(true)
        let result = try receipt(f.bridge.execute(.setQuiet(enabled: false), expected: f.bridge.snapshot()))
        XCTAssertEqual(result.outcome, .applied); XCTAssertFalse(f.session.isQuiet); XCTAssertTrue(f.session.focusQuiet)
        XCTAssertTrue(result.detail.contains("专注安静"))
        XCTAssertEqual(try receipt(f.bridge.execute(.setQuiet(enabled: false), expected: f.bridge.snapshot())).outcome, .alreadySatisfied)
        let revision = f.session.quietRevision; f.session.setQuiet(false); XCTAssertEqual(f.session.quietRevision, revision)
        f.bridge.dispose(); f.focus.pause(); XCTAssertGreaterThan(notifications, 1)
        f.input.modal = true
        if case .expired = f.bridge.execute(.resumeFocus, expected: f.bridge.snapshot()) {} else { XCTFail("blocked command accepted") }
    }
}
