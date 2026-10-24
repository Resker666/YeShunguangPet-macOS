import Foundation
import AVFoundation
import Speech
import CoreAudio

@MainActor final class NativeSpeechInput: VoiceInputProviding {
    private let driver: any NativeSpeechInputDriving
    private var token: UUID?
    private var finishing = false
    private var callback: (@MainActor (UUID, VoiceInputEvent) -> Void)?
    init(driver: (any NativeSpeechInputDriving)? = nil) { self.driver = driver ?? SystemSpeechInputDriver() }
    func permissionStatus() -> VoicePermissions { driver.permissionStatus() }
    func availability() -> VoiceInputAvailability { driver.availability() }
    func requestPermissions() async -> VoicePermissions {
        var status = driver.permissionStatus()
        if status.microphone == .notDetermined { status.microphone = await driver.requestMicrophone() }
        guard !Task.isCancelled, status.microphone == .authorized else { return status }
        if status.speech == .notDetermined { status.speech = await driver.requestSpeech() }
        return status
    }
    func start(token: UUID, mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (UUID, VoiceInputEvent) -> Void) throws {
        guard self.token == nil else { throw VoiceInputFailure.busy }
        guard driver.permissionStatus().isAuthorized else { throw VoiceInputFailure.permissionDenied }
        let available = driver.availability()
        guard mode != .onDevice || available.supportsOnDevice else { throw VoiceInputFailure.onDeviceUnavailable }
        guard available.isAvailable else { throw VoiceInputFailure.serviceUnavailable }
        guard try driver.inputFormat().isValid else { throw VoiceInputFailure.invalidFormat }
        self.token = token; finishing = false; callback = onEvent
        do { try driver.begin(mode: mode) { [weak self] event in self?.receive(event, token: token) } }
        catch { cancel(token: token); throw (error as? VoiceInputFailure) ?? .recognitionFailed }
    }
    func finish(token: UUID) {
        guard self.token == token, !finishing else { return }
        finishing = true; driver.endAudio()
    }
    func cancel(token: UUID) {
        guard self.token == token else { return }
        self.token = nil; finishing = false; callback = nil; driver.cancel()
    }
    private func receive(_ event: VoiceInputEvent, token: UUID) {
        guard self.token == token, let callback else { return }
        switch event {
        case .partial: break
        case .final, .failed: cancel(token: token)
        }
        callback(token, event)
    }
}

// The tap may run on a realtime thread. Closing this feed waits for any append
// already in flight, before MainActor ends audio or releases the request.
private final class SpeechAudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request?.append(buffer) } }
    func close() { lock.withLock { request = nil } }
}

private final class SpeechAvailabilityProxy: NSObject, SFSpeechRecognizerDelegate, @unchecked Sendable {
    private let unavailable: @Sendable () -> Void
    init(unavailable: @escaping @Sendable () -> Void) { self.unavailable = unavailable }
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available { unavailable() }
    }
}

@MainActor private final class SystemSpeechInputDriver: NativeSpeechInputDriving {
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var feed: SpeechAudioFeed?
    private var tapInstalled = false
    private var observer: (any NSObjectProtocol)?
    private var availabilityProxy: SpeechAvailabilityProxy?
    private func speechRecognizer() -> SFSpeechRecognizer? {
        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")); recognizer?.queue = .main }
        return recognizer
    }
    func permissionStatus() -> VoicePermissions {
        let microphone: VoiceAuthorization
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .authorized
        case .notDetermined: microphone = .notDetermined
        case .restricted: microphone = .restricted
        default: microphone = .denied
        }
        return VoicePermissions(microphone: microphone, speech: Self.authorization(SFSpeechRecognizer.authorizationStatus()))
    }
    private nonisolated static func authorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoiceAuthorization {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }
    func requestMicrophone() async -> VoiceAuthorization {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in continuation.resume(returning: granted ? .authorized : .denied) }
        }
    }
    func requestSpeech() async -> VoiceAuthorization {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: Self.authorization(status)) }
        }
    }
    func availability() -> VoiceInputAvailability {
        let value = speechRecognizer()
        return VoiceInputAvailability(isAvailable: value?.isAvailable == true, supportsOnDevice: value?.supportsOnDeviceRecognition == true)
    }
    func inputFormat() throws -> VoiceAudioFormat {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { throw VoiceInputFailure.noDevice }
        let engine = AVAudioEngine()
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard VoiceAudioFormat(sampleRate: input.sampleRate, channels: input.channelCount).isValid else { throw VoiceInputFailure.invalidFormat }
        let format = engine.inputNode.outputFormat(forBus: 0)
        self.engine = engine; self.format = format
        return VoiceAudioFormat(sampleRate: format.sampleRate, channels: format.channelCount)
    }
    func begin(mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) throws {
        guard let engine, let format, let recognizer = speechRecognizer() else { throw VoiceInputFailure.serviceUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = mode == .onDevice
        self.request = request
        let feed = SpeechAudioFeed(request); self.feed = feed
        let proxy = SpeechAvailabilityProxy { Task { @MainActor in onEvent(.failed(.serviceUnavailable)) } }
        availabilityProxy = proxy; recognizer.delegate = proxy
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in onEvent(.failed(.interrupted)) }
        }
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString, isFinal = result?.isFinal == true, failed = error != nil
            Task { @MainActor in
                if let text { onEvent(isFinal ? .final(text) : .partial(text)) }
                if failed, !isFinal { onEvent(.failed(.recognitionFailed)) }
            }
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
        tapInstalled = true
        engine.prepare(); try engine.start()
    }
    private func stopCapture() {
        feed?.close(); feed = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    }
    func endAudio() { stopCapture(); request?.endAudio() }
    func cancel() {
        stopCapture(); task?.cancel(); task = nil; request = nil
        recognizer?.delegate = nil; availabilityProxy = nil; engine = nil; format = nil
    }
}
