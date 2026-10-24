import Foundation
import AVFoundation

@MainActor final class NativeSpeechOutput: VoiceOutputProviding {
    private let driver: any NativeSpeechOutputDriving
    private let stopTimeout: Duration
    private var token: UUID?
    private var callback: (@MainActor (UUID, VoiceOutputEvent) -> Void)?
    private var stopping = false
    private var waiters = [CheckedContinuation<Bool, Never>]()
    private var timeoutTask: Task<Void, Never>?
    var onVoicesChanged: (() -> Void)?
    init(driver: (any NativeSpeechOutputDriving)? = nil, stopTimeout: Duration = .seconds(1)) {
        self.driver = driver ?? SystemSpeechOutputDriver(); self.stopTimeout = stopTimeout
        self.driver.onEvent = { [weak self] token, event in self?.receive(token, event) }
        self.driver.onVoicesChanged = { [weak self] in self?.onVoicesChanged?() }
    }
    func installedVoices() -> [SystemVoice] {
        driver.installedVoices().filter { $0.isAppleVoice && !$0.isPersonalVoice && $0.language.lowercased().hasPrefix("zh") }
    }
    func speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID, onEvent: @escaping @MainActor (UUID, VoiceOutputEvent) -> Void) throws {
        guard !stopping, !driver.isSpeaking, self.token == nil else { throw VoiceOutputFailure.busy }
        guard !text.isEmpty, text.utf16.count <= 8000, rate.isFinite, (0.35...0.65).contains(rate) else { throw VoiceOutputFailure.invalid }
        guard installedVoices().contains(where: { $0.id == voiceIdentifier }) else { throw VoiceOutputFailure.unavailable }
        self.token = token; callback = onEvent
        do { try driver.speak(text, voiceIdentifier: voiceIdentifier, rate: rate, token: token) }
        catch { self.token = nil; callback = nil; throw VoiceOutputFailure.unavailable }
    }
    func stop() async -> Bool {
        if stopping {
            if !driver.isSpeaking { completeStop(true); return true }
            return await withCheckedContinuation { waiters.append($0) }
        }
        stopping = true; driver.stop()
        if !driver.isSpeaking { completeStop(true); return true }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            timeoutTask = Task { [weak self, stopTimeout] in
                do { try await Task.sleep(for: stopTimeout) } catch { return }
                guard let self else { return }
                self.completeStop(!self.driver.isSpeaking)
            }
        }
    }
    private func completeStop(_ confirmed: Bool) {
        timeoutTask?.cancel(); timeoutTask = nil; stopping = false
        if confirmed { token = nil; callback = nil }
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(returning: confirmed) }
    }
    private func receive(_ token: UUID, _ event: VoiceOutputEvent) {
        guard self.token == token else { return }
        let callback = callback
        // A matching terminal event retires only its own utterance.
        self.token = nil; self.callback = nil
        if stopping, !driver.isSpeaking { completeStop(true) }
        callback?(token, event)
    }
}

private final class SpeechOutputProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens = [ObjectIdentifier: UUID]()
    private let event: @Sendable (UUID, VoiceOutputEvent) -> Void
    init(event: @escaping @Sendable (UUID, VoiceOutputEvent) -> Void) { self.event = event }
    func register(_ utterance: AVSpeechUtterance, token: UUID) { lock.withLock { tokens[ObjectIdentifier(utterance)] = token } }
    private func emit(_ utterance: AVSpeechUtterance, event: VoiceOutputEvent) {
        let token = lock.withLock { tokens.removeValue(forKey: ObjectIdentifier(utterance)) }
        if let token { self.event(token, event) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { emit(utterance, event: .finished) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { emit(utterance, event: .cancelled) }
}

@MainActor private final class SystemSpeechOutputDriver: NativeSpeechOutputDriving {
    private var synthesizer: AVSpeechSynthesizer?
    private var proxy: SpeechOutputProxy?
    private var observer: VoiceNotificationToken?
    var onEvent: (@MainActor (UUID, VoiceOutputEvent) -> Void)?
    var onVoicesChanged: (() -> Void)?
    var isSpeaking: Bool { synthesizer?.isSpeaking == true }
    private func observeVoices() {
        guard observer == nil else { return }
        observer = VoiceNotificationToken(NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onVoicesChanged?() }
        })
    }
    func installedVoices() -> [SystemVoice] {
        observeVoices()
        return AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoice(id: $0.identifier, name: $0.name, language: $0.language,
                        isAppleVoice: $0.identifier.hasPrefix("com.apple."), isPersonalVoice: $0.voiceTraits.contains(.isPersonalVoice))
        }
    }
    func speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID) throws {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier), voice.identifier.hasPrefix("com.apple."), !voice.voiceTraits.contains(.isPersonalVoice), voice.language.lowercased().hasPrefix("zh") else { throw VoiceOutputFailure.unavailable }
        if synthesizer == nil {
            let synthesizer = AVSpeechSynthesizer()
            let proxy = SpeechOutputProxy { [weak self] token, event in Task { @MainActor in self?.onEvent?(token, event) } }
            self.synthesizer = synthesizer; self.proxy = proxy; synthesizer.delegate = proxy
        }
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice; utterance.rate = Float(rate)
        proxy?.register(utterance, token: token); synthesizer?.speak(utterance)
    }
    func stop() { _ = synthesizer?.stopSpeaking(at: .immediate) }
}

private final class VoiceNotificationToken: @unchecked Sendable {
    private let value: any NSObjectProtocol
    init(_ value: any NSObjectProtocol) { self.value = value }
    deinit { NotificationCenter.default.removeObserver(value) }
}
