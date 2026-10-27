import Foundation
import PetCore

@MainActor final class ControlledVoiceInput: VoiceInputProviding {
    var permissionsValue = VoicePermissions(microphone: .authorized, speech: .authorized)
    var availabilityValue = VoiceInputAvailability(isAvailable: true, supportsOnDevice: true)
    var holdPermissions = false
    private var permissionContinuation: CheckedContinuation<VoicePermissions, Never>?
    private(set) var permissionRequests = 0
    private(set) var starts = [(token: UUID, mode: VoiceRecognitionMode)]()
    private(set) var finishes = [UUID](), cancellations = [UUID]()
    private var callbacks = [UUID: @MainActor (UUID, VoiceInputEvent) -> Void]()
    var onStart: ((UUID) -> Void)?, onFinish: ((UUID) -> Void)?
    var startFailure: VoiceInputFailure?
    var finishCount: Int { finishes.count }
    func permissionStatus() -> VoicePermissions { permissionsValue }
    func requestPermissions() async -> VoicePermissions {
        permissionRequests += 1
        if holdPermissions { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permissionsValue
    }
    func releasePermissions() { holdPermissions = false; permissionContinuation?.resume(returning: permissionsValue); permissionContinuation = nil }
    func availability() -> VoiceInputAvailability { availabilityValue }
    func start(token: UUID, mode: VoiceRecognitionMode, onEvent: @escaping @MainActor (UUID, VoiceInputEvent) -> Void) throws {
        if let startFailure { throw startFailure }
        starts.append((token, mode)); callbacks[token] = onEvent; onStart?(token)
    }
    func finish(token: UUID) { finishes.append(token); onFinish?(token) }
    func cancel(token: UUID) { cancellations.append(token) }
    func emit(_ token: UUID, _ event: VoiceInputEvent) { callbacks[token]?(token, event) }
}

@MainActor final class ControlledVoiceOutput: VoiceOutputProviding {
    struct Spoken { let text, voiceIdentifier: String; let rate: Double; let token: UUID }
    var voices = [SystemVoice(id: "test-zh", name: "测试中文", language: "zh-CN", isAppleVoice: true, isPersonalVoice: false)]
    var onVoicesChanged: (() -> Void)?
    var stopResult = true, holdStop = false
    private var stopsWaiting = [CheckedContinuation<Bool, Never>]()
    private(set) var stops = 0, spoken = [Spoken]()
    var onSpeak: (() -> Void)?, speakFailure: VoiceOutputFailure?
    private var callbacks = [UUID: @MainActor (UUID, VoiceOutputEvent) -> Void]()
    func installedVoices() -> [SystemVoice] { voices }
    func speak(_ text: String, voiceIdentifier: String, rate: Double, token: UUID, onEvent: @escaping @MainActor (UUID, VoiceOutputEvent) -> Void) throws {
        if let speakFailure { throw speakFailure }
        spoken.append(.init(text: text, voiceIdentifier: voiceIdentifier, rate: rate, token: token)); callbacks[token] = onEvent; onSpeak?()
    }
    func stop() async -> Bool { stops += 1; if holdStop { return await withCheckedContinuation { stopsWaiting.append($0) } }; return stopResult }
    func releaseStop() { holdStop = false; let waiting = stopsWaiting; stopsWaiting = []; for waiter in waiting { waiter.resume(returning: stopResult) } }
    func emit(_ token: UUID, _ event: VoiceOutputEvent) { callbacks[token]?(token, event) }
}

@MainActor final class VoiceControllerHarness {
    let root: URL
    let persistence: ControlledChatPersistence, writes: ChatWriteQueue
    let settings: ChatVoicePreferencesController
    let input = ControlledVoiceInput(), output = ControlledVoiceOutput()
    var clock: Duration = .zero
    var snapshot = VoiceDraftSnapshot(character: .init(id: "robin", name: "知更鸟", description: "角色", skinRevision: 0), revision: 0, text: "")
    var canInput = true
    var insertions = [VoiceInsertion]()
    var environment = VoiceEnvironment(surface: .conversation)
    var routing: (any VoiceOutputRouting)?
    var selection: VoiceRouteSelection = .system
    lazy var controller = ChatVoiceController(settings: settings, services: .init(input: input, routing: routing ?? VoiceOutputRouter(system: output)), now: { [weak self] in self?.clock ?? .zero }, draft: { [weak self] in self?.snapshot }, canRecognize: { [weak self] in self?.canInput == true }, apply: { [weak self] expected, insertion in
        guard let self, self.snapshot == expected else { return false }
        self.insertions.append(insertion)
        self.snapshot = .init(character: expected.character, revision: expected.revision + 1, text: insertion.text)
        return true
    }, resolveSelection: { [weak self] _ in self?.selection ?? .system })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-harness-" + UUID().uuidString)
        persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json"))
        writes = ChatWriteQueue(persistence: persistence)
        settings = ChatVoicePreferencesController(persistence: persistence, writes: writes)
    }
    static func makeEnabled() async throws -> VoiceControllerHarness {
        let h = try VoiceControllerHarness()
        try await chatEventually { h.settings.isLoaded }
        h.settings.apply(.init(enabled: true)); await h.writes.waitForPending()
        h.controller.updateEnvironment(h.environment)
        return h
    }
    func advance(by duration: Duration) { clock += duration; controller.serviceDeadlines() }
    func setEnvironment(_ value: VoiceEnvironment) { environment = value; controller.updateEnvironment(value) }
    func close() async {
        controller.dispose(); input.releasePermissions(); output.releaseStop(); settings.dispose()
        await persistence.releaseWrite(); await writes.waitForPending()
        try? FileManager.default.removeItem(at: root)
    }
    func reply(_ revision: UInt64 = 1, text: String = "完整回复") -> VoiceSavedReply { .init(id: UUID(), context: snapshot.character, requestRevision: revision, text: text) }
}
