import Foundation
import CoreFoundation
import Darwin
import PetCore

enum LocalVoiceIssue: Error, LocalizedError, Equatable, Sendable {
    case unavailable, engineUnconfigured, libraryProtected, voiceMissing, systemUnavailable, systemPlayback, protocolFailure, timeout, memoryLimit, generation, invalidAudio, playback, cleanup, stopping, cancelled
    var errorDescription: String? {
        switch self {
        case .unavailable: "本地语音引擎不可用，请检查本机环境和语音包。"
        case .engineUnconfigured: "本机尚未准备可用的角色语音引擎。"
        case .libraryProtected: "本地语音库索引受保护，请在语音设置中检查。"
        case .voiceMissing: "角色绑定的本地音色缺失或校验失败，请重新导入。"
        case .systemUnavailable: "没有可用的系统中文音色，请在系统辅助功能的朗读内容中下载中文音色。"
        case .systemPlayback: "系统朗读未能完成，可手动重试。"
        case .protocolFailure: "本地语音引擎返回了无效响应。"
        case .timeout: "本地语音生成超时，请缩短文字后重试。"
        case .memoryLimit: "本地语音引擎内存用量超过限制，已停止本次生成。"
        case .generation: "本地语音未能生成；首版主要支持中文，缺少的语言资源不会自动下载。"
        case .invalidAudio: "本地引擎未生成有效音频。"
        case .playback: "本地音频播放失败。"
        case .cleanup: "本地语音临时音频未能清理，请重试停止以清理资源。"
        case .stopping: "本地语音资源尚未确认停止，请重试停止。"
        case .cancelled: "本次本地语音已停止。"
        }
    }
}
@MainActor protocol LocalVoiceProcessDriving: AnyObject, Sendable {
    var hasResources: Bool { get }
    func start(configuration: LocalVoiceEngineConfiguration, voice: ResolvedLocalVoice, workDirectory: URL, session: UUID) async throws
    func generate(requestID: UUID, text: String, speedFactor: Double) async throws -> URL
    func stop() async -> Bool
}

struct LocalVoiceProcessLimits: Sendable {
    var ready = 45.0, generate = 120.0, stopGrace = 2.0, killGrace = 2.0, monitorInterval = 0.5
    var maximumRSS: UInt64 = 8 * 1024 * 1024 * 1024
}

@MainActor final class LocalVoiceProcess: LocalVoiceProcessDriving {
    private let workerURL: URL
    private let limits: LocalVoiceProcessLimits
    private let rss: @Sendable (pid_t) -> UInt64?
    private var child: LocalVoiceChild?
    private var stopTask: Task<Bool, Never>?
    var hasResources: Bool { child?.hasResources == true }
    var ownedPID: pid_t? { child?.ownedPID }
    init(workerURL: URL, limits: LocalVoiceProcessLimits = .init(), rss: @escaping @Sendable (pid_t) -> UInt64? = LocalVoiceChild.residentBytes) {
        self.workerURL = workerURL; self.limits = limits; self.rss = rss
    }
    func start(configuration: LocalVoiceEngineConfiguration, voice: ResolvedLocalVoice, workDirectory: URL, session: UUID) async throws {
        guard !hasResources, stopTask == nil else { throw LocalVoiceIssue.stopping }
        let child = LocalVoiceChild(workerURL: workerURL, configuration: configuration, voice: voice, workDirectory: workDirectory, session: session, limits: limits, rss: rss)
        self.child = child
        try await child.start()
    }
    func generate(requestID: UUID, text: String, speedFactor: Double) async throws -> URL {
        guard let child, stopTask == nil else { throw LocalVoiceIssue.unavailable }
        return try await child.generate(requestID: requestID, text: text, speedFactor: speedFactor)
    }
    func stop() async -> Bool {
        if let stopTask { return await stopTask.value }
        guard let current = child else { return true }
        let task = Task { [self] in
            let confirmed = await current.stop()
            if child === current, confirmed { child = nil }
            stopTask = nil
            return confirmed
        }
        stopTask = task
        return await task.value
    }
}

// All shared state is protected by lock. Pipe callbacks and launch/close run off
// the main actor, and each instance owns exactly one Foundation child process.
private final class LocalVoiceChild: @unchecked Sendable {
    private enum Response: Sendable { case ready, result }
    private enum Expected { case ready, result(UUID) }
    private let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
    private let lock = NSLock()
    private let session: UUID, workDirectory: URL, limits: LocalVoiceProcessLimits
    private let rss: @Sendable (pid_t) -> UInt64?
    private var launched = false, launchFinished = false, exited = false, closed = false, stopping = false
    private var fault: LocalVoiceIssue?, expected: Expected?, pending: CheckedContinuation<Response, Error>?
    private var stdout = Data(), stdoutBytes = 0, stderrBytes = 0
    private var timer: DispatchSourceTimer?, deadline: UInt64 = 0
    var hasResources: Bool { lock.withLock { !launchFinished || !closed || (launched && !exited) } }
    var ownedPID: pid_t? { lock.withLock { launched && !exited ? process.processIdentifier : nil } }
    init(workerURL: URL, configuration: LocalVoiceEngineConfiguration, voice: ResolvedLocalVoice, workDirectory: URL, session: UUID, limits: LocalVoiceProcessLimits, rss: @escaping @Sendable (pid_t) -> UInt64?) {
        self.session = session; self.workDirectory = workDirectory; self.limits = limits; self.rss = rss
        process.executableURL = configuration.pythonURL
        process.arguments = ["-u", "-B", workerURL.path, "--engine-root", configuration.versionRoot.path, "--voice-root", voice.directory.path, "--work-root", workDirectory.path, "--session-id", session.uuidString]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "zh_CN.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "OMP_NUM_THREADS": "4", "MKL_NUM_THREADS": "4"]
        process.currentDirectoryURL = workDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        process.terminationHandler = { [weak self] _ in self?.didExit() }
    }
    func start() async throws {
        _ = try await withCheckedThrowingContinuation { continuation in
            begin(.ready, seconds: limits.ready, continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                if lock.withLock({ stopping }) {
                    lock.withLock { launchFinished = true; exited = true }; closeHandles(); return
                }
                for handle in [output.fileHandleForReading, error.fileHandleForReading] {
                    let fd = handle.fileDescriptor
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                }
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle, stderr: false) }
                error.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle, stderr: true) }
                do {
                    // A worker can close stdin between readiness and our write.
                    // Convert EPIPE into the existing error path, only for this pipe.
                    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                        throw LocalVoiceIssue.unavailable
                    }
                    try process.run()
                    lock.withLock { launched = true; launchFinished = true }
                    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
                    if lock.withLock({ stopping }) { terminate() }
                } catch {
                    lock.withLock { launchFinished = true; exited = true }
                    fail(.unavailable); closeHandles()
                }
            }
        }
    }
    func generate(requestID: UUID, text: String, speedFactor: Double) async throws -> URL {
        guard !text.isEmpty, text.utf16.count <= 600, speedFactor.isFinite, (0.7...1.3).contains(speedFactor) else { throw LocalVoiceIssue.generation }
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "command": "generate", "sessionID": session.uuidString, "requestID": requestID.uuidString, "text": text, "speedFactor": speedFactor]) + Data([10])
        guard data.count <= 65536 else { throw LocalVoiceIssue.protocolFailure }
        _ = try await withCheckedThrowingContinuation { continuation in
            begin(.result(requestID), seconds: limits.generate, continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch { fail(.unavailable) }
            }
        }
        return workDirectory.appendingPathComponent(requestID.uuidString + ".wav")
    }
    private func begin(_ next: Expected, seconds: Double, continuation: CheckedContinuation<Response, Error>) {
        let rejected: LocalVoiceIssue? = lock.withLock {
            if let fault { return fault }
            guard pending == nil, !stopping, !exited else { return .stopping }
            pending = continuation; expected = next; stdoutBytes = 0; stderrBytes = 0
            deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + min(seconds, limits.monitorInterval), repeating: limits.monitorInterval)
            timer.setEventHandler { [weak self] in self?.monitor() }
            self.timer = timer; timer.resume()
            return nil
        }
        if let rejected { continuation.resume(throwing: rejected) }
    }
    private func monitor() {
        let snapshot: (UInt64, pid_t?)? = lock.withLock {
            guard pending != nil, !stopping else { return nil }
            return (deadline, launched && !exited ? process.processIdentifier : nil)
        }
        guard let snapshot else { return }
        if DispatchTime.now().uptimeNanoseconds >= snapshot.0 { fail(.timeout); return }
        if let pid = snapshot.1, let bytes = rss(pid), bytes > limits.maximumRSS { fail(.memoryLimit) }
    }
    static func residentBytes(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_resident_size : nil
    }
    private func read(_ handle: FileHandle, stderr: Bool) {
            // FileHandle.read(upToCount:) may wait to fill the requested count.
            // A pipe response is short and the worker waits for our next command.
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else {
                if count < 0, errno != EAGAIN, errno != EINTR, !lock.withLock({ stopping || closed }) { fail(.unavailable) }
                return
            }
            let data = Data(bytes.prefix(count))
            var completion: CheckedContinuation<Response, Error>?, response: Response?, issue: LocalVoiceIssue?
            lock.withLock {
                guard !stopping, !closed else { return }
                if stderr {
                    stderrBytes += data.count
                    if stderrBytes > 1048576 { issue = .protocolFailure }
                    return
                }
                stdoutBytes += data.count
                guard stdoutBytes <= 262144 else { issue = .protocolFailure; return }
                stdout.append(data)
                while let newline = stdout.firstIndex(of: 10) {
                    let count = stdout.distance(from: stdout.startIndex, to: newline) + 1
                    guard count <= 65536 else { issue = .protocolFailure; return }
                    let line = Data(stdout.prefix(count)); stdout.removeFirst(count)
                    do {
                        let parsed = try decode(line)
                        guard let waiter = pending else { throw LocalVoiceIssue.protocolFailure }
                        completion = waiter; response = parsed; pending = nil; expected = nil
                        timer?.cancel(); timer = nil
                    } catch let error as LocalVoiceIssue { issue = error; return }
                    catch { issue = .protocolFailure; return }
                }
                if stdout.count >= 65536 { issue = .protocolFailure }
            }
            if let completion, let response { completion.resume(returning: response) }
            if let issue { fail(issue) }
    }
    private func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), !["f", "d"].contains(String(cString: value.objCType)) else { return nil }
        return Int(exactly: value.int64Value)
    }
    private func decode(_ data: Data) throws -> Response {
        try StrictJSON.validate(data, maximumBytes: 65536)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], integer(object["v"]) == 1,
              let rawSession = object["sessionID"] as? String, UUID(uuidString: rawSession) == session else { throw LocalVoiceIssue.protocolFailure }
        switch (object["event"] as? String, expected) {
        case ("ready", .ready):
            guard Set(object.keys) == ["v", "event", "sessionID", "profile"], object["profile"] as? String == LocalVoiceManifest.profile else { throw LocalVoiceIssue.protocolFailure }
            return .ready
        case ("result", .result(let request)):
            guard Set(object.keys) == ["v", "event", "sessionID", "requestID", "sampleRate", "frames"],
                  UUID(uuidString: object["requestID"] as? String ?? "") == request, integer(object["sampleRate"]) == 32000,
                  let frames = integer(object["frames"]), (1...7680000).contains(frames) else { throw LocalVoiceIssue.protocolFailure }
            return .result
        case ("error", _):
            let allowed: Set<String> = ["v", "event", "sessionID", "requestID", "code"]
            guard Set(object.keys).isSubset(of: allowed), let code = object["code"] as? String, ["resource", "generation", "protocol"].contains(code) else { throw LocalVoiceIssue.protocolFailure }
            if case .result(let request) = expected, UUID(uuidString: object["requestID"] as? String ?? "") != request { throw LocalVoiceIssue.protocolFailure }
            throw code == "resource" ? LocalVoiceIssue.unavailable : code == "generation" ? .generation : .protocolFailure
        default: throw LocalVoiceIssue.protocolFailure
        }
    }
    private func fail(_ issue: LocalVoiceIssue) {
        let waiter = lock.withLock {
            fault = fault ?? issue; let waiter = pending; pending = nil; expected = nil
            timer?.cancel(); timer = nil
            return waiter
        }
        waiter?.resume(throwing: issue)
        terminate()
    }
    private func terminate() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let running = lock.withLock { launched && !exited }
            if running, process.isRunning { process.terminate() }
        }
    }
    private func didExit() {
        let waiter = lock.withLock {
            exited = true; let waiter = pending; pending = nil; expected = nil; timer?.cancel(); timer = nil; return waiter
        }
        waiter?.resume(throwing: lock.withLock { fault ?? (stopping ? .cancelled : .unavailable) })
        closeHandles()
    }
    private func closeHandles() {
        output.fileHandleForReading.readabilityHandler = nil; error.fileHandleForReading.readabilityHandler = nil
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting, error.fileHandleForReading, error.fileHandleForWriting] { try? handle.close() }
        lock.withLock { closed = true }
    }
    func stop() async -> Bool {
        let waiter = lock.withLock {
            stopping = true; let waiter = pending; pending = nil; expected = nil; timer?.cancel(); timer = nil; return waiter
        }
        waiter?.resume(throwing: LocalVoiceIssue.cancelled)
        DispatchQueue.global(qos: .utility).async { [self] in try? input.fileHandleForWriting.close() }
        terminate()
        if await wait(seconds: limits.stopGrace) { return true }
        // No name search, process group signal or PID from an external file.
        let owned = lock.withLock { launched && !exited ? process.processIdentifier : nil }
        if let owned, process.isRunning { _ = Darwin.kill(owned, SIGKILL) }
        return await wait(seconds: limits.killGrace)
    }
    private func wait(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(seconds * 1_000_000_000))
        while hasResources, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return !hasResources
    }
}
