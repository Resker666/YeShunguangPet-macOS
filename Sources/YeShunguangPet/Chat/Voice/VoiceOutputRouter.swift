import Foundation
import PetCore

@MainActor final class VoiceOutputRouter: VoiceOutputRouting {
    private let system: any VoiceOutputProviding
    private let local: LocalVoiceOutput?
    private var request: RoutedVoiceRequest?
    private var callback: (@MainActor (UUID, RoutedVoiceEvent) -> Void)?
    private var transition: Task<Void, Never>?, stopTask: Task<Bool, Never>?
    private var systemClean = false, systemMayHaveResources = false, attemptedFallback = false
    var onVoicesChanged: (() -> Void)?
    var hasResources: Bool { request != nil || systemMayHaveResources || local?.hasResources == true || stopTask != nil }
    init(system: any VoiceOutputProviding, local: LocalVoiceOutput? = nil) {
        self.system = system; self.local = local
        system.onVoicesChanged = { [weak self] in self?.onVoicesChanged?() }
    }
    func installedSystemVoices() -> [SystemVoice] {
        system.installedVoices().filter { $0.isAppleVoice && !$0.isPersonalVoice && $0.language.lowercased().hasPrefix("zh") }
    }
    func prepare(for selection: VoiceRouteSelection) async -> Bool {
        if let stopTask, !(await stopTask.value) { return false }
        if request != nil, !(await stop()) { return false }
        if !systemClean {
            let confirmed = await system.stop()
            systemClean = confirmed; systemMayHaveResources = !confirmed
            guard confirmed else { return false }
        }
        switch selection {
        case .local(let voice): return await local?.prepare(voice: voice) ?? true
        case .system, .unavailable:
            if let local, local.hasResources { return await local.stop() }
            return true
        }
    }
    func speak(_ request: RoutedVoiceRequest, onEvent: @escaping @MainActor (UUID, RoutedVoiceEvent) -> Void) throws {
        guard self.request == nil, stopTask == nil else { throw LocalVoiceIssue.stopping }
        guard !request.text.isEmpty, request.text.utf16.count <= 8000, request.rate.isFinite, (0.35...0.65).contains(request.rate) else { throw VoiceOutputFailure.invalid }
        guard request.isValid() else { return }
        self.request = request; callback = onEvent; attemptedFallback = false
        switch request.selection {
        case .system: startSystem(request.token)
        case .unavailable(.cancelled): finish(request.token, .cancelled)
        case .unavailable(let issue): fallback(request.token, issue: issue)
        case .local(let voice):
            if request.text.utf16.count > 600 { useSystemForLongText(request.token); return }
            guard let local else { fallback(request.token, issue: .unavailable); return }
            do {
                try local.start(.init(token: request.token, voice: voice, text: request.text, rate: request.rate)) { [weak self] token, event in self?.receiveLocal(token, event, voice: voice) }
            } catch { fallback(request.token, issue: error as? LocalVoiceIssue ?? .unavailable) }
        }
    }
    private func valid(_ token: UUID) -> Bool { request?.token == token && request?.isValid() == true && stopTask == nil }
    @discardableResult private func publish(_ token: UUID, _ event: RoutedVoiceEvent) -> Bool {
        guard valid(token) else { return false }
        callback?(token, event)
        return valid(token)
    }
    private func finish(_ token: UUID, _ event: RoutedVoiceEvent) {
        guard request?.token == token else { return }
        let callback = callback, shouldPublish = valid(token)
        request = nil; self.callback = nil; transition = nil
        if shouldPublish { callback?(token, event) }
    }
    private func startSystem(_ token: UUID) {
        guard valid(token), let request else { return }
        let voices = installedSystemVoices()
        guard let voice = voices.first(where: { $0.id == request.preferredSystemVoiceID }) ?? voices.first(where: { $0.language.lowercased() == "zh-cn" }) ?? voices.first else {
            finish(token, .failed(.systemUnavailable)); return
        }
        guard publish(token, .phase(.starting)) else { return }
        systemClean = false; systemMayHaveResources = true
        do {
            try system.speak(request.text, voiceIdentifier: voice.id, rate: request.rate, token: token) { [weak self] token, event in
                guard let self, self.request?.token == token else { return }
                self.systemMayHaveResources = false; self.systemClean = true
                self.finish(token, event == .finished ? .finished : event == .cancelled ? .cancelled : .failed(.systemPlayback))
            }
            guard publish(token, .actualIdentity(.init(backend: .system, displayName: voice.name, systemVoiceID: voice.id))) else { return }
            _ = publish(token, .phase(.playing))
        } catch {
            // The system driver may retain resources after an unsuccessful start.
            // Explicit stop remains available; never attempt a second playback.
            finish(token, .failed(.systemUnavailable))
        }
    }
    private func receiveLocal(_ token: UUID, _ event: LocalVoiceOutputEvent, voice: ResolvedLocalVoice) {
        guard valid(token) else { return }
        switch event {
        case .phase(let phase):
            if phase == .playing, !publish(token, .actualIdentity(.init(backend: .local, displayName: voice.manifest.name, libraryID: voice.libraryUUID))) { return }
            _ = publish(token, .phase(phase == .starting ? .starting : phase == .generating ? .generating : .playing))
        case .finished: finish(token, .finished)
        case .cancelled: finish(token, .cancelled)
        case .failed(let issue, let playbackStarted):
            if playbackStarted || issue == .cancelled || issue == .cleanup { finish(token, .failed(issue)) }
            else { fallback(token, issue: issue) }
        }
    }
    private func useSystemForLongText(_ token: UUID) {
        transition = Task { [weak self] in
            guard let self, self.publish(token, .phase(.stopping)) else { return }
            let confirmed = await self.local?.stop() ?? true
            guard !Task.isCancelled, self.valid(token) else { return }
            guard confirmed else { self.finish(token, .failed(.stopping)); return }
            guard self.publish(token, .notice("本地音色单次最多 600 个 UTF-16 单元，本次使用系统音色朗读全文。")) else { return }
            self.startSystem(token)
        }
    }
    private func fallback(_ token: UUID, issue: LocalVoiceIssue) {
        guard valid(token), !attemptedFallback else { return }
        attemptedFallback = true
        transition = Task { [weak self] in
            guard let self, self.publish(token, .phase(.stopping)) else { return }
            let confirmed = await self.local?.stop() ?? true
            guard !Task.isCancelled, self.valid(token) else { return }
            guard confirmed else { self.finish(token, .failed(.stopping)); return }
            guard self.publish(token, .notice("\(issue.localizedDescription) 本次改用系统音色。")) else { return }
            self.startSystem(token)
        }
    }
    func stop() async -> Bool {
        request = nil; callback = nil; transition?.cancel(); transition = nil
        if let stopTask { return await stopTask.value }
        let task = Task { [self] in
            let systemStop = Task { await system.stop() }
            let localStop = Task { await local?.stop() ?? true }
            let results = await (systemStop.value, localStop.value)
            systemClean = results.0; systemMayHaveResources = !results.0
            stopTask = nil
            return results.0 && results.1
        }
        stopTask = task
        return await task.value
    }
}
