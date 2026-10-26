import Foundation
import AVFoundation
import XCTest

@MainActor private final class TestSpeechOutputDriver: NativeSpeechOutputDriving {
    var voices = [SystemVoice(id: "zh", name: "中文", language: "zh-CN", isAppleVoice: true, isPersonalVoice: false)]
    var isSpeaking = false
    var stopImmediately = false
    var spoken = [UUID](), stops = 0
    var onEvent: (@MainActor (UUID, VoiceOutputEvent) -> Void)?
    var onVoicesChanged: (() -> Void)?
    func installedVoices() -> [SystemVoice] { voices }
    func speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID) throws { isSpeaking = true; spoken.append(token) }
    func stop() { stops += 1; if stopImmediately { isSpeaking = false } }
}

@MainActor final class NativeSpeechOutputTests: XCTestCase {
    func testVoiceNotificationProducerDoesNotWaitForMainActor() async throws {
        let center = NotificationCenter(), posting = DispatchSemaphore(value: 0), posted = DispatchSemaphore(value: 0)
        var updates = 0
        let observation = SpeechVoicesObservation(center: center) { updates += 1 }
        DispatchQueue.global().async {
            posting.signal()
            center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
            posted.signal()
        }
        // Model speechVoices() waiting synchronously for its background worker.
        // The worker must be able to finish posting while MainActor is occupied.
        XCTAssertEqual(posting.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(posted.wait(timeout: .now() + 1), .success, "Voice service must not wait for the UI to deliver its notification")
        XCTAssertEqual(updates, 0)
        try await chatEventually { updates == 1 }
        withExtendedLifetime(observation) {}
    }

    func testVoiceNotificationOnMainIsDeferredAndObservationIsRemoved() async throws {
        let center = NotificationCenter()
        var updates = 0
        var observation: SpeechVoicesObservation? = SpeechVoicesObservation(center: center) { updates += 1 }
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        XCTAssertEqual(updates, 0)
        try await chatEventually { updates == 1 }
        XCTAssertNotNil(observation)
        observation = nil
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(updates, 1)
    }

    func testBusySpeakDoesNotQueueAndLateCancelKeepsNewToken() async throws {
        let driver = TestSpeechOutputDriver(), first = UUID(), second = UUID()
        let output = NativeSpeechOutput(driver: driver, stopTimeout: .milliseconds(20))
        var received = [UUID]()
        try output.speak("一", voiceIdentifier: "zh", rate: 0.5, token: first) { token, _ in received.append(token) }
        XCTAssertThrowsError(try output.speak("排队", voiceIdentifier: "zh", rate: 0.5, token: second, onEvent: { _, _ in }))
        let stopping = Task { await output.stop() }
        try await chatEventually { driver.stops == 1 }
        XCTAssertThrowsError(try output.speak("仍在停止", voiceIdentifier: "zh", rate: 0.5, token: second, onEvent: { _, _ in }))
        driver.isSpeaking = false; driver.onEvent?(first, .cancelled)
        let stopped = await stopping.value; XCTAssertTrue(stopped)
        try output.speak("二", voiceIdentifier: "zh", rate: 0.5, token: second) { token, _ in received.append(token) }
        driver.onEvent?(first, .cancelled)
        XCTAssertThrowsError(try output.speak("旧回调未清空新段", voiceIdentifier: "zh", rate: 0.5, token: UUID(), onEvent: { _, _ in }))
        XCTAssertEqual(driver.spoken, [first, second]); XCTAssertFalse(received.contains(second))
        driver.isSpeaking = false; driver.onEvent?(second, .finished)
        XCTAssertEqual(received.last, second)
    }
    func testStopRequiresObservedStoppedStateAndIsBounded() async throws {
        let driver = TestSpeechOutputDriver(), token = UUID()
        let output = NativeSpeechOutput(driver: driver, stopTimeout: .milliseconds(15))
        try output.speak("未停", voiceIdentifier: "zh", rate: 0.5, token: token, onEvent: { _, _ in })
        let stopped = await output.stop(); XCTAssertFalse(stopped)
        XCTAssertThrowsError(try output.speak("不可继续", voiceIdentifier: "zh", rate: 0.5, token: UUID(), onEvent: { _, _ in }))
        driver.isSpeaking = false
        let confirmed = await output.stop(); XCTAssertTrue(confirmed)
        let idle = await output.stop(); XCTAssertTrue(idle)
    }
    func testDuplicateStopSharesConfirmationAndSynchronousStopWorks() async throws {
        let driver = TestSpeechOutputDriver(), token = UUID()
        let output = NativeSpeechOutput(driver: driver, stopTimeout: .milliseconds(30))
        try output.speak("一", voiceIdentifier: "zh", rate: 0.5, token: token, onEvent: { _, _ in })
        let one = Task { await output.stop() }, two = Task { await output.stop() }
        try await chatEventually { driver.stops == 1 }
        driver.isSpeaking = false; driver.onEvent?(token, .cancelled)
        let a = await one.value, b = await two.value; XCTAssertTrue(a && b)
        driver.stopImmediately = true
        try output.speak("二", voiceIdentifier: "zh", rate: 0.5, token: UUID(), onEvent: { _, _ in })
        let stopped = await output.stop(); XCTAssertTrue(stopped)
    }
    func testVoiceListExcludesPersonalAndNonAppleVoices() throws {
        let driver = TestSpeechOutputDriver()
        driver.voices += [.init(id: "private", name: "个人", language: "zh-CN", isAppleVoice: true, isPersonalVoice: true), .init(id: "vendor", name: "第三方", language: "zh-CN", isAppleVoice: false, isPersonalVoice: false), .init(id: "en", name: "English", language: "en-US", isAppleVoice: true, isPersonalVoice: false)]
        let output = NativeSpeechOutput(driver: driver)
        XCTAssertEqual(output.installedVoices().map(\.id), ["zh"])
        var updates = 0; output.onVoicesChanged = { updates += 1 }; driver.onVoicesChanged?(); XCTAssertEqual(updates, 1)
        XCTAssertThrowsError(try output.speak("不可用", voiceIdentifier: "private", rate: 0.5, token: UUID(), onEvent: { _, _ in }))
        XCTAssertThrowsError(try output.speak("语速无效", voiceIdentifier: "zh", rate: .nan, token: UUID(), onEvent: { _, _ in }))
        driver.voices = []; XCTAssertTrue(output.installedVoices().isEmpty)
        XCTAssertThrowsError(try output.speak("无音色", voiceIdentifier: "zh", rate: 0.5, token: UUID(), onEvent: { _, _ in }))
        XCTAssertTrue(driver.spoken.isEmpty)
    }
}
