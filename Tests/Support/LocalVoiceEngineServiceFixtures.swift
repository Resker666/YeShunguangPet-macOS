import Foundation
import PetCore

final class EngineGate: @unchecked Sendable {
    private let lock = NSLock(); private var stored = false
    let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { stored } }
    func blockOnce() { let first = lock.withLock { if stored { return false }; stored = true; return true }; if first { semaphore.wait() } }
}
final class EngineFailureFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored = true
    var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
@MainActor final class ControlledEngineProbe: LocalVoiceEngineProbing {
    var hasResources = false, hold = false, fail = false, stopResult = true
    var runs = 0, stops = 0
    var waiter: CheckedContinuation<LocalVoiceEngineProbeReport, Error>?
    func run(configuration: LocalVoiceEngineConfiguration, requestID: UUID) async throws -> LocalVoiceEngineProbeReport {
        runs += 1; hasResources = true
        if fail { throw LocalVoiceError("probe failure") }
        if hold { return try await withCheckedThrowingContinuation { waiter = $0 } }
        hasResources = false; return .init(pythonVersion:"3.12.14",profile:LocalVoiceManifest.profile,sourceCommit:LocalVoiceEngineDescriptor.sourceCommit)
    }
    func stop() async -> Bool {
        stops += 1
        if stopResult { hasResources = false; waiter?.resume(throwing:CancellationError()); waiter = nil }
        return stopResult
    }
}
