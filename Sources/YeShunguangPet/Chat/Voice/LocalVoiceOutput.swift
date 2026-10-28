import Foundation
import Darwin
import PetCore

enum LocalVoicePhase: Equatable, Sendable { case starting, generating, playing }
enum LocalVoiceOutputEvent: Equatable, Sendable {
    case phase(LocalVoicePhase), finished, cancelled, failed(issue: LocalVoiceIssue, playbackStarted: Bool)
}
struct LocalVoiceRequest: Sendable {
    let token: UUID
    let voice: ResolvedLocalVoice
    let text: String
    let rate: Double
}
enum LocalVoiceAudioSnapshot {
    static func read(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LocalVoiceIssue.invalidAudio }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, (44...33554432).contains(before.st_size) else { throw LocalVoiceIssue.invalidAudio }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw LocalVoiceIssue.invalidAudio }
            if count == 0 { break }
            guard count <= 33554432 - data.count else { throw LocalVoiceIssue.invalidAudio }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, after.st_size == data.count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw LocalVoiceIssue.invalidAudio }
        do { _ = try LocalVoicePCM.validate(data, maximumBytes: 33554432, minimumSeconds: 0, maximumSeconds: 240) }
        catch { throw LocalVoiceIssue.invalidAudio }
        return data
    }
}

@MainActor final class LocalVoiceOutput {
    private let process: any LocalVoiceProcessDriving, player: any LocalVoicePlayerDriving
    private let configuration: @Sendable () async throws -> LocalVoiceEngineConfiguration
    private let now: @MainActor () -> TimeInterval
    private let idleSeconds: TimeInterval
    private let removeAudio: @Sendable (URL) throws -> Void
    private var voice: ResolvedLocalVoice?, workDirectory: URL?, active: UUID?
    private var callback: (@MainActor (UUID, LocalVoiceOutputEvent) -> Void)?
    private var generation: Task<Void, Never>?, idleTask: Task<Void, Never>?, cleanupTask: Task<Void, Never>?, stopTask: Task<Bool, Never>?
    private var played = false
    private var idleSince: TimeInterval?
    var hasResources: Bool { active != nil || process.hasResources || player.hasResources || workDirectory != nil || stopTask != nil }
    init(process: any LocalVoiceProcessDriving, player: any LocalVoicePlayerDriving, configuration: @escaping @Sendable () async throws -> LocalVoiceEngineConfiguration,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, idleSeconds: TimeInterval = 180,
         removeAudio: @escaping @Sendable (URL) throws -> Void = { url in
             if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
         }) {
        self.process = process; self.player = player; self.configuration = configuration; self.now = now; self.idleSeconds = idleSeconds
        self.removeAudio = removeAudio
    }
    convenience init(dataRoot: URL, workerURL: URL) {
        self.init(process: LocalVoiceProcess(workerURL: workerURL), player: LocalVoicePlayer(), configuration: {
            try await Task.detached(priority: .userInitiated) { try LocalVoiceEngineDescriptor.load(dataRoot: dataRoot).resolve(dataRoot: dataRoot) }.value
        })
    }
    func prepare(voice: ResolvedLocalVoice) async -> Bool {
        if let cleanupTask { await cleanupTask.value }
        if let stopTask, !(await stopTask.value) { return false }
        if active == nil, self.voice == voice, process.hasResources, !player.hasResources {
            idleTask?.cancel(); idleTask = nil; idleSince = nil
            return true
        }
        if hasResources, !(await stop()) { return false }
        self.voice = voice
        return true
    }
    func start(_ request: LocalVoiceRequest, onEvent: @escaping @MainActor (UUID, LocalVoiceOutputEvent) -> Void) throws {
        guard active == nil, stopTask == nil, !player.hasResources else { throw LocalVoiceIssue.stopping }
        guard !request.text.isEmpty, request.text.utf16.count <= 600, request.rate.isFinite, (0.35...0.65).contains(request.rate) else { throw LocalVoiceIssue.generation }
        guard !process.hasResources || voice == request.voice else { throw LocalVoiceIssue.stopping }
        voice = request.voice; active = request.token; callback = onEvent; played = false
        idleTask?.cancel(); idleTask = nil; idleSince = nil
        generation = Task { [weak self] in await self?.run(request) }
    }
    private func current(_ token: UUID) -> Bool { active == token && stopTask == nil && !Task.isCancelled }
    private func emit(_ token: UUID, _ phase: LocalVoicePhase) { if current(token) { callback?(token, .phase(phase)) } }
    private func run(_ request: LocalVoiceRequest) async {
        do {
            if !process.hasResources {
                emit(request.token, .starting)
                guard current(request.token) else { return }
                let config = try await configuration()
                guard current(request.token) else { return }
                let directory = try await Task.detached(priority: .userInitiated) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("YSGPetVoice-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    return url
                }.value
                guard current(request.token) else { try? FileManager.default.removeItem(at: directory); return }
                workDirectory = directory
                try await process.start(configuration: config, voice: request.voice, workDirectory: directory, session: UUID())
            }
            guard current(request.token) else { return }
            emit(request.token, .generating)
            guard current(request.token) else { return }
            let url = try await process.generate(requestID: request.token, text: request.text, speedFactor: request.rate / 0.5)
            guard current(request.token) else { return }
            guard url == workDirectory?.appendingPathComponent(request.token.uuidString + ".wav") else { throw LocalVoiceIssue.invalidAudio }
            let data = try await Task.detached(priority: .userInitiated) { try LocalVoiceAudioSnapshot.read(url) }.value
            guard current(request.token) else { return }
            try player.play(data: data, token: request.token) { [weak self] token, event in self?.receive(token, event) }
        } catch {
            guard current(request.token) else { return }
            finish(request.token, .failed(issue: error as? LocalVoiceIssue ?? .unavailable, playbackStarted: played))
        }
    }
    private func receive(_ token: UUID, _ event: LocalVoicePlayerEvent) {
        guard current(token) else { return }
        switch event {
        case .started: played = true; emit(token, .playing)
        case .finished: finish(token, .finished)
        case .failed: finish(token, .failed(issue: .playback, playbackStarted: played))
        }
    }
    private func finish(_ token: UUID, _ event: LocalVoiceOutputEvent) {
        guard active == token, cleanupTask == nil else { return }
        let audio = workDirectory?.appendingPathComponent(token.uuidString + ".wav"), removeAudio = removeAudio
        cleanupTask = Task { [self] in
            let cleaned = await Task.detached(priority: .utility) {
                do { if let audio { try removeAudio(audio) }; return true } catch { return false }
            }.value
            cleanupTask = nil
            guard current(token) else { return }
            let callback = callback
            active = nil; self.callback = nil; generation = nil
            callback?(token, cleaned ? event : .failed(issue: .cleanup, playbackStarted: played))
            guard cleaned, active == nil, stopTask == nil, process.hasResources else { return }
            scheduleIdle()
        }
    }
    private func scheduleIdle() {
        idleSince = now()
        idleTask = Task { [weak self, idleSeconds] in
            do { try await Task.sleep(for: .nanoseconds(Int64(idleSeconds * 1_000_000_000))) } catch { return }
            await self?.checkIdle()
        }
    }
    func checkIdle() async {
        guard active == nil, stopTask == nil, let idleSince, now() - idleSince >= idleSeconds else { return }
        _ = await stop()
    }
    func stop() async -> Bool {
        if let stopTask { return await stopTask.value }
        generation?.cancel(); generation = nil; idleTask?.cancel(); idleTask = nil; idleSince = nil
        let oldToken = active, oldCallback = callback
        active = nil; callback = nil
        let directory = workDirectory
        let cleanupTask = cleanupTask
        let task = Task { [self] in
            await cleanupTask?.value
            async let outputStopped = player.stop()
            async let engineStopped = process.stop()
            let results = await (outputStopped, engineStopped)
            var confirmed = false
            if results.0, results.1 {
                confirmed = await Task.detached(priority: .utility) {
                    do {
                        if let directory, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                        return true
                    } catch { return false }
                }.value
            }
            if confirmed { voice = nil; workDirectory = nil }
            stopTask = nil
            if let oldToken { oldCallback?(oldToken, .cancelled) }
            return confirmed
        }
        stopTask = task
        return await task.value
    }
}
