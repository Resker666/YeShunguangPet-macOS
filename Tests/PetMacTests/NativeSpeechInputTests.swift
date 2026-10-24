import Foundation
import XCTest

@MainActor private final class TestSpeechInputDriver: NativeSpeechInputDriving {
    var permissions = VoicePermissions(microphone: .authorized, speech: .authorized)
    var available = VoiceInputAvailability(isAvailable: true, supportsOnDevice: true)
    var format = VoiceAudioFormat(sampleRate: 48000, channels: 1)
    var holdMicrophone = false
    var pendingMicrophone: CheckedContinuation<VoiceAuthorization, Never>?
    var asked = [String](), modes = [VoiceRecognitionMode]()
    var ends = 0, cancels = 0
    var listeners = [@MainActor (VoiceInputEvent) -> Void]()
    func permissionStatus() -> VoicePermissions { permissions }
    func requestMicrophone() async -> VoiceAuthorization {
        asked.append("microphone")
        if holdMicrophone { return await withCheckedContinuation { pendingMicrophone = $0 } }
        return permissions.microphone
    }
    func requestSpeech() async -> VoiceAuthorization { asked.append("speech"); return permissions.speech }
    func availability() -> VoiceInputAvailability { available }
    func inputFormat() throws -> VoiceAudioFormat { format }
    func begin(mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) throws { modes.append(mode); listeners.append(onEvent) }
    func endAudio() { ends += 1 }
    func cancel() { cancels += 1 }
}

@MainActor final class NativeSpeechInputTests: XCTestCase {
    func testInvalidInputFormatNeverStartsCapture() throws {
        for format in [VoiceAudioFormat(sampleRate: 0, channels: 1), VoiceAudioFormat(sampleRate: 48000, channels: 0), VoiceAudioFormat(sampleRate: .nan, channels: 1)] {
            let driver = TestSpeechInputDriver(); driver.format = format
            let input = NativeSpeechInput(driver: driver)
            XCTAssertThrowsError(try input.start(token: UUID(), mode: .onDevice, onEvent: { _, _ in }))
            XCTAssertTrue(driver.modes.isEmpty)
        }
    }

    func testCancelledPermissionTaskDoesNotAskSecondPermission() async throws {
        let driver = TestSpeechInputDriver(); driver.permissions = .init(microphone: .notDetermined, speech: .notDetermined); driver.holdMicrophone = true
        let input = NativeSpeechInput(driver: driver)
        let task = Task { await input.requestPermissions() }
        try await chatEventually { driver.pendingMicrophone != nil }
        task.cancel(); driver.permissions.microphone = .authorized
        driver.pendingMicrophone?.resume(returning: .authorized); driver.pendingMicrophone = nil
        _ = await task.value
        XCTAssertEqual(driver.asked, ["microphone"])
        XCTAssertTrue(driver.modes.isEmpty)
    }

    func testFinishAndCancelAreIdempotentAndOldEventsCannotReachNextSession() throws {
        let driver = TestSpeechInputDriver()
        let tested = NativeSpeechInput(driver: driver), first = UUID(), next = UUID()
        tested.cancel(token: UUID()); XCTAssertEqual(driver.cancels, 0)
        var events = [VoiceInputEvent]()
        try tested.start(token: first, mode: .onDevice) { _, event in events.append(event) }
        tested.finish(token: first); tested.finish(token: first)
        XCTAssertEqual(driver.ends, 1)
        driver.listeners[0](.partial("预览")); driver.listeners[0](.final("完整")); driver.listeners[0](.final("重复"))
        XCTAssertEqual(events, [.partial("预览"), .final("完整")])
        XCTAssertEqual(driver.cancels, 1)
        try tested.start(token: next, mode: .onDevice) { _, event in events.append(event) }
        driver.listeners[0](.failed(.recognitionFailed))
        XCTAssertEqual(driver.cancels, 1)
        tested.cancel(token: next); tested.cancel(token: next)
        XCTAssertEqual(driver.cancels, 2)
        driver.listeners[1](.final("取消后不能出现"))
        XCTAssertEqual(events.count, 2)
    }

    func testModeIsNeverSilentlyChangedAndPermissionIsRequired() throws {
        let driver = TestSpeechInputDriver(), token = UUID()
        let input = NativeSpeechInput(driver: driver)
        driver.available.supportsOnDevice = false
        XCTAssertThrowsError(try input.start(token: token, mode: .onDevice, onEvent: { _, _ in }))
        XCTAssertTrue(driver.modes.isEmpty)
        try input.start(token: token, mode: .allowNetwork, onEvent: { _, _ in })
        XCTAssertEqual(driver.modes, [.allowNetwork])
        XCTAssertThrowsError(try input.start(token: UUID(), mode: .allowNetwork, onEvent: { _, _ in }))
        input.cancel(token: token)
        driver.permissions.microphone = .denied
        XCTAssertThrowsError(try input.start(token: UUID(), mode: .allowNetwork, onEvent: { _, _ in }))
        XCTAssertEqual(driver.modes.count, 1)
    }

    func testEarlyFinalAndInterruptionCleanWithoutRetry() throws {
        let driver = TestSpeechInputDriver()
        let tested = NativeSpeechInput(driver: driver)
        try tested.start(token: UUID(), mode: .onDevice, onEvent: { _, _ in })
        driver.listeners[0](.failed(.interrupted))
        XCTAssertEqual(driver.cancels, 1)
        XCTAssertEqual(driver.modes.count, 1)
        try tested.start(token: UUID(), mode: .onDevice, onEvent: { _, _ in })
        driver.listeners[1](.final("提前完成"))
        XCTAssertEqual(driver.ends, 0)
        XCTAssertEqual(driver.cancels, 2)
    }

    func testAppManifestDeclaresBothVoicePurposes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/YeShunguangPet/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            XCTAssertFalse((info[key] as? String ?? "").isEmpty, key)
        }
    }
}
