import Foundation

enum VoiceRecognitionMode: Equatable, Sendable { case onDevice, allowNetwork }
enum VoiceAuthorization: Equatable, Sendable { case notDetermined, authorized, denied, restricted }
struct VoicePermissions: Equatable, Sendable {
    var microphone: VoiceAuthorization
    var speech: VoiceAuthorization
    var isAuthorized: Bool { microphone == .authorized && speech == .authorized }
}
struct VoiceInputAvailability: Equatable, Sendable { var isAvailable, supportsOnDevice: Bool }
struct VoiceAudioFormat: Equatable, Sendable {
    let sampleRate: Double
    let channels: UInt32
    var isValid: Bool { sampleRate.isFinite && sampleRate > 0 && channels > 0 }
}
enum VoiceInputFailure: Error, LocalizedError, Equatable, Sendable {
    case noDevice, invalidFormat, onDeviceUnavailable, serviceUnavailable, permissionDenied, interrupted, recognitionFailed, busy
    var errorDescription: String? {
        switch self {
        case .noDevice: "未找到可用麦克风，请检查系统声音输入设置。"
        case .invalidFormat: "当前输入设备格式不可用，请检查麦克风后重试。"
        case .onDeviceUnavailable: "本机中文识别当前不可用。可选择允许本次在线识别并重新录音。"
        case .serviceUnavailable: "系统语音识别当前不可用，请稍后重试。"
        case .permissionDenied: "需要麦克风与语音识别权限，请在系统隐私与安全性设置中检查。"
        case .interrupted: "输入设备或识别服务发生变化，本次识别已停止。"
        case .recognitionFailed: "本次识别未完成，可检查已有预览或重新录音。"
        case .busy: "当前语音活动尚未结束。"
        }
    }
}
enum VoiceInputEvent: Equatable, Sendable { case partial(String), final(String), failed(VoiceInputFailure) }
@MainActor protocol VoiceInputProviding: AnyObject {
    func permissionStatus() -> VoicePermissions
    func requestPermissions() async -> VoicePermissions
    func availability() -> VoiceInputAvailability
    func start(token: UUID, mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (UUID, VoiceInputEvent) -> Void) throws
    func finish(token: UUID)
    func cancel(token: UUID)
}

// The driver owns OS resources; the adapter owns token/authorization policy.
@MainActor protocol NativeSpeechInputDriving: AnyObject {
    func permissionStatus() -> VoicePermissions
    func requestMicrophone() async -> VoiceAuthorization
    func requestSpeech() async -> VoiceAuthorization
    func availability() -> VoiceInputAvailability
    func inputFormat() throws -> VoiceAudioFormat
    func begin(mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) throws
    func endAudio()
    func cancel()
}

struct SystemVoice: Equatable, Sendable {
    let id, name, language: String
    let isAppleVoice, isPersonalVoice: Bool
}
enum VoiceOutputEvent: Equatable, Sendable { case finished, cancelled, failed }
enum VoiceOutputFailure: Error, LocalizedError {
    case busy, unavailable, invalid
    var errorDescription: String? {
        switch self {
        case .busy: "系统朗读尚未确认停止，请稍后重试。"
        case .unavailable: "没有可用的系统中文音色，请在系统辅助功能的朗读内容中下载中文音色。"
        case .invalid: "朗读文字或语速无效。"
        }
    }
}
@MainActor protocol VoiceOutputProviding: AnyObject {
    func installedVoices() -> [SystemVoice]
    func speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID, onEvent: @escaping @MainActor (UUID, VoiceOutputEvent) -> Void) throws
    func stop() async -> Bool
    var onVoicesChanged: (() -> Void)? { get set }
}
@MainActor protocol NativeSpeechOutputDriving: AnyObject {
    var isSpeaking: Bool { get }
    var onEvent: (@MainActor (UUID, VoiceOutputEvent) -> Void)? { get set }
    var onVoicesChanged: (() -> Void)? { get set }
    func installedVoices() -> [SystemVoice]
    func speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID) throws
    func stop()
}
@MainActor struct VoiceServices {
    let input: any VoiceInputProviding
    let output: any VoiceOutputRouting
    init(input: any VoiceInputProviding, output: any VoiceOutputProviding) {
        self.input = input; self.output = VoiceOutputRouter(system: output)
    }
    init(input: any VoiceInputProviding, routing: any VoiceOutputRouting) {
        self.input = input; output = routing
    }
}
