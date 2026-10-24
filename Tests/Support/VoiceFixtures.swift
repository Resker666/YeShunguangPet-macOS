import Foundation

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
