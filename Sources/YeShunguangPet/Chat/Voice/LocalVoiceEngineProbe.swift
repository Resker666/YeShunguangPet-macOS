import Foundation
import CoreFoundation
import Darwin
import PetCore

struct LocalVoiceEngineProbeReport: Equatable, Sendable {
    let pythonVersion, profile, sourceCommit: String
}
@MainActor protocol LocalVoiceEngineProbing: AnyObject, Sendable {
    var hasResources: Bool { get }
    func run(configuration: LocalVoiceEngineConfiguration, requestID: UUID) async throws -> LocalVoiceEngineProbeReport
    func stop() async -> Bool
}
@MainActor final class LocalVoiceEngineProbe: LocalVoiceEngineProbing {
    struct Limits: Sendable {
        var timeout = 120.0, stopGrace = 2.0, killGrace = 2.0
        var sendSignal: @Sendable (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) }
    }
    private let scriptURL: URL, limits: Limits
    private var child: EngineProbeChild?
    private var stopTask: Task<Bool, Never>?
    var hasResources: Bool { child?.hasResources == true }
    var ownedPID: pid_t? { child?.ownedPID }
    init(scriptURL: URL, limits: Limits = .init()) { self.scriptURL = scriptURL; self.limits = limits }
    func run(configuration: LocalVoiceEngineConfiguration, requestID: UUID) async throws -> LocalVoiceEngineProbeReport {
        guard child == nil, stopTask == nil else { throw LocalVoiceError("引擎自检尚未停止") }
        let current = EngineProbeChild(configuration: configuration, scriptURL: scriptURL, requestID: requestID, limits: limits)
        child = current
        defer { if child === current, !current.hasResources { child = nil } }
        return try await withTaskCancellationHandler { try await current.run() } onCancel: { current.cancel() }
    }
    func stop() async -> Bool {
        if let stopTask { return await stopTask.value }
        guard let current = child else { return true }
        let task = Task { [self] in
            let stopped = await current.stop()
            if stopped, child === current { child = nil }
            stopTask = nil; return stopped
        }
        stopTask = task; return await task.value
    }
}

// This private serial queue owns Process, all handles and all I/O. Only the
// cancellation/resource flags cross threads, protected by lock.
private final class EngineProbeChild: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pet.engine.probe", qos: .userInitiated)
    private let lock = NSLock(), process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let requestID: UUID, limits: LocalVoiceEngineProbe.Limits
    private var cancelled = false, resources = true, pid: pid_t?
    private var stdout = Data(), stderr = Data()
    var hasResources: Bool { lock.withLock { resources } }
    var ownedPID: pid_t? { lock.withLock { pid } }
    init(configuration: LocalVoiceEngineConfiguration, scriptURL: URL, requestID: UUID, limits: LocalVoiceEngineProbe.Limits) {
        self.requestID = requestID; self.limits = limits
        process.executableURL = configuration.pythonURL
        process.arguments = ["-u", "-B", scriptURL.path, "--engine-root", configuration.versionRoot.path, "--cache-root", configuration.cacheURL.path, "--request-id", requestID.uuidString]
        process.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"zh_CN.UTF-8", "PYTHONDONTWRITEBYTECODE":"1", "PYTHONNOUSERSITE":"1", "HF_HUB_OFFLINE":"1", "TRANSFORMERS_OFFLINE":"1", "HF_HUB_DISABLE_TELEMETRY":"1", "TORIO_USE_FFMPEG":"0", "TORCHAUDIO_USE_SOX":"0"]
        process.currentDirectoryURL = configuration.versionRoot
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
    }
    func cancel() { lock.withLock { cancelled = true } }
    func run() async throws -> LocalVoiceEngineProbeReport {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try execute()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func close() {
        for handle in [input.fileHandleForReading,input.fileHandleForWriting,output.fileHandleForReading,output.fileHandleForWriting,errors.fileHandleForReading,errors.fileHandleForWriting] { try? handle.close() }
        lock.withLock { resources = false; pid = nil }
    }
    private func drain(_ handle: FileHandle, into data: inout Data, maximum: Int) throws {
        var bytes = [UInt8](repeating:0,count:65536)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { if count < 0, errno != EAGAIN { throw LocalVoiceError("自检管道读取失败") }; return }
            guard count <= maximum - data.count else { throw LocalVoiceError("自检输出超过安全上限") }
            data.append(contentsOf: bytes.prefix(count))
            if maximum == 262144 {
                guard data.split(separator:10,omittingEmptySubsequences:false).allSatisfy({ $0.count < 65536 }) else { throw LocalVoiceError("自检响应行过长") }
            }
            // Bound each poll too, so a noisy pipe cannot starve cancellation.
            if count == bytes.count { return }
        }
    }
    private func execute() throws -> LocalVoiceEngineProbeReport {
        if lock.withLock({ cancelled }) { close(); throw CancellationError() }
        do { try process.run() } catch { close(); throw LocalVoiceError("自检无法启动 Python，请检查引擎") }
        lock.withLock { pid = process.processIdentifier }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        for handle in [output.fileHandleForReading,errors.fileHandleForReading] { _ = fcntl(handle.fileDescriptor,F_SETFL,fcntl(handle.fileDescriptor,F_GETFL) | O_NONBLOCK) }
        let deadline = ContinuousClock.now + .nanoseconds(Int64(limits.timeout * 1e9))
        var fault: Error?
        while process.isRunning {
            do {
                try drain(output.fileHandleForReading,into:&stdout,maximum:262144)
                try drain(errors.fileHandleForReading,into:&stderr,maximum:1048576)
            } catch { fault = error; break }
            if lock.withLock({ cancelled }) { fault = CancellationError(); break }
            if ContinuousClock.now >= deadline { fault = LocalVoiceError("引擎自检超时，可重试检查"); break }
            Thread.sleep(forTimeInterval:0.01)
        }
        if let fault {
            guard terminateAndClose() else { throw LocalVoiceError("自检进程尚未确认退出，请重试停止") }
            throw fault
        }
        defer { close() }
        try drain(output.fileHandleForReading,into:&stdout,maximum:262144)
        try drain(errors.fileHandleForReading,into:&stderr,maximum:1048576)
        guard process.terminationStatus == 0 else {
            let category = String(decoding:stderr,as:UTF8.self)
            throw LocalVoiceError(category.contains("dependency:") ? "引擎依赖缺失，请修复安装" : category.contains("runtime:") ? "引擎 Python 或架构不兼容" : "引擎资源或离线自检失败，请修复安装")
        }
        if lock.withLock({ cancelled }) { throw CancellationError() }
        return try decode()
    }
    private func decode() throws -> LocalVoiceEngineProbeReport {
        let lines = stdout.split(separator:10,omittingEmptySubsequences:false)
        guard lines.count == 2, lines.last!.isEmpty, lines[0].count < 65536 else { throw LocalVoiceError("自检响应数量或长度无效") }
        let line = Data(lines[0])
        try StrictJSON.validate(line,maximumBytes:65536)
        guard let values = try JSONSerialization.jsonObject(with:line) as? [String:Any], Set(values.keys) == ["v","event","requestID","pythonVersion","profile","sourceCommit"],
              let v = values["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), !["f","d"].contains(String(cString:v.objCType)), v.intValue == 1,
              values["event"] as? String == "checked", let id = values["requestID"] as? String, UUID(uuidString:id) == requestID,
              let python = values["pythonVersion"] as? String, let version = ReleaseVersion(tag:python), version.description == python, version.major == 3, version.minor == 12,
              values["profile"] as? String == LocalVoiceManifest.profile, values["sourceCommit"] as? String == LocalVoiceEngineDescriptor.sourceCommit else { throw LocalVoiceError("自检返回身份无效") }
        return .init(pythonVersion:python,profile:LocalVoiceManifest.profile,sourceCommit:LocalVoiceEngineDescriptor.sourceCommit)
    }
    private func terminateAndClose() -> Bool {
        try? input.fileHandleForWriting.close()
        if process.isRunning { limits.sendSignal(process.processIdentifier, SIGTERM) }
        wait(limits.stopGrace)
        if process.isRunning { limits.sendSignal(process.processIdentifier, SIGKILL) }
        wait(limits.killGrace)
        guard !process.isRunning else { return false }
        close(); return true
    }
    private func wait(_ seconds: Double) {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(seconds * 1e9))
        while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval:0.01) }
    }
    func stop() async -> Bool {
        cancel()
        // Serialized after execute: if its bounded stop could not confirm exit,
        // this retry still owns that exact Process and those same handles.
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !hasResources { continuation.resume(returning:true) }
                else { continuation.resume(returning:terminateAndClose()) }
            }
        }
    }
}
