import Foundation
import PetCore

protocol LocalVoiceEngineWorking: Sendable {
    func preview(folder: URL) async throws -> LocalVoiceEnginePreview
    func acquireLease() async throws
    func begin(_ preview: LocalVoiceEnginePreview) async throws -> LocalVoiceEngineCandidate
    func copy(_ candidate: LocalVoiceEngineCandidate, progress: @escaping @Sendable (LocalVoiceEngineProgress)->Void) async throws
    func activate(_ candidate: LocalVoiceEngineCandidate) async throws -> LocalVoiceEngineDescriptor
    func discard(_ candidate: LocalVoiceEngineCandidate) async throws
    func releaseLease() async
    func current() async -> LocalVoiceEngineSnapshot
}
actor LocalVoiceEngineWorker: LocalVoiceEngineWorking {
    private let store: LocalVoiceEngineStore
    private var lease: LocalVoiceEngineLease?
    init(dataRoot: URL, hooks: LocalVoiceEngineStore.Hooks = .live) { store = .init(dataRoot:dataRoot,hooks:hooks) }
    func preview(folder: URL) throws -> LocalVoiceEnginePreview { try Task.checkCancellation(); return try LocalVoiceEnginePackage.preview(folder:folder) }
    func acquireLease() throws { if lease == nil { lease = try store.acquire() } }
    func begin(_ preview: LocalVoiceEnginePreview) throws -> LocalVoiceEngineCandidate {
        try Task.checkCancellation(); try acquireLease(); return try store.begin(preview,lease:lease!)
    }
    func copy(_ candidate: LocalVoiceEngineCandidate, progress: @escaping @Sendable (LocalVoiceEngineProgress)->Void) throws {
        // Store callbacks are synchronous on this actor, with at most one UI
        // progress delivery per 100 ms (plus phase/final changes).
        let throttle = EngineProgressThrottle(deliver:progress)
        try store.copy(candidate,progress:{ throttle.emit($0) },checkCancelled:{ Task.isCancelled })
    }
    func activate(_ candidate: LocalVoiceEngineCandidate) throws -> LocalVoiceEngineDescriptor {
        try acquireLease(); return try store.activate(candidate,lease:lease!,checkCancelled:{ Task.isCancelled })
    }
    func discard(_ candidate: LocalVoiceEngineCandidate) throws { try acquireLease(); try store.discard(versionID:candidate.versionID,lease:lease!) }
    func releaseLease() { lease?.release(); lease = nil }
    func current() -> LocalVoiceEngineSnapshot {
        let status = LocalVoiceEngineDescriptor.status(dataRoot:store.dataRoot)
        guard let descriptor = try? LocalVoiceEngineDescriptor.load(dataRoot:store.dataRoot), let configuration = try? descriptor.resolve(dataRoot:store.dataRoot) else { return .init(status:status) }
        return .init(status:status,descriptor:descriptor,configuration:configuration)
    }
}
private final class EngineProgressThrottle: @unchecked Sendable {
    // Sendable closure signature is used by Store; callbacks are synchronous.
    private let lock = NSLock(), deliver: @Sendable (LocalVoiceEngineProgress)->Void
    private var last: ContinuousClock.Instant?, phase: LocalVoiceEngineWorkPhase?
    init(deliver: @escaping @Sendable (LocalVoiceEngineProgress)->Void) { self.deliver = deliver }
    func emit(_ value:LocalVoiceEngineProgress) {
        let send = lock.withLock {
            let now = ContinuousClock.now
            if phase != value.phase || value.completedBytes == value.totalBytes || last.map({ $0.duration(to:now) >= .milliseconds(100) }) != false {
                last = now; phase = value.phase; return true
            }; return false
        }
        if send { deliver(value) }
    }
}
