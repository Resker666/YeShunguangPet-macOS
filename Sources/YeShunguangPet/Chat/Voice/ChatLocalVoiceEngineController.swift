import Foundation
import Combine
import PetCore

enum LocalVoiceEnginePhase: Equatable { case idle, previewing, awaitingConfirmation, stopping, copying, verifying, probing, activating, installed, checking, cancelling, failed }
@MainActor final class ChatLocalVoiceEngineController: ObservableObject {
    @Published private var revision: UInt64 = 0
    private let worker: any LocalVoiceEngineWorking, probe: any LocalVoiceEngineProbing
    private let canStart: @MainActor ()->Bool, stopOutput: @MainActor () async->Bool, onActivated: @MainActor ()->Void
    let isSupported: Bool
    private(set) var phase: LocalVoiceEnginePhase = .idle
    private(set) var preview: LocalVoiceEnginePreview?, progress: LocalVoiceEngineProgress?, error: String?
    private(set) var snapshot = LocalVoiceEngineSnapshot()
    private var operation: Task<Void,Never>?, stopping: Task<Bool,Never>?
    private var pendingActivation: LocalVoiceEngineCandidate?, cleanupPending: LocalVoiceEngineCandidate?
    private var disposed = false, terminating = false, notifyActivated = false
    private var previewGeneration: UInt64 = 0
    var isBusy: Bool { operation != nil || stopping != nil }
    var blocksServices: Bool { (operation != nil && phase != .previewing) || stopping != nil || probe.hasResources }
    var hasPendingResources: Bool { isBusy || probe.hasResources }
    var hasUnsaved: Bool { pendingActivation != nil || cleanupPending != nil }
    var terminationError: String? { hasUnsaved || probe.hasResources ? error ?? "引擎切换或清理尚未完成，可重试本地保存与停止。" : nil }
    var canBegin: Bool { isSupported && !disposed && !terminating && !isBusy && !hasUnsaved && !probe.hasResources && canStart() }
    var canRetry: Bool { !disposed && !isBusy && (hasUnsaved || probe.hasResources) }
    init(worker: any LocalVoiceEngineWorking, probe: any LocalVoiceEngineProbing, canStart: @escaping @MainActor ()->Bool, stopOutput: @escaping @MainActor () async->Bool, onActivated: @escaping @MainActor ()->Void, isSupported: Bool = ChatLocalVoiceEngineController.hostSupported) {
        self.worker = worker; self.probe = probe; self.canStart = canStart; self.stopOutput = stopOutput; self.onActivated = onActivated; self.isSupported = isSupported
    }
    static var hostSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    private func changed() { if !disposed { revision &+= 1 } }
    private func start(_ body: @escaping @MainActor () async->Void) {
        operation = Task { [self] in
            await body(); operation = nil
            if notifyActivated { notifyActivated = false; if !disposed && !terminating { onActivated() } }
            changed()
        }; changed()
    }
    func refreshSnapshot() {
        guard !disposed, !isBusy else { return }
        start { [self] in snapshot = await worker.current() }
    }
    func preview(folder: URL) {
        guard canBegin, preview == nil else { return }
        previewGeneration &+= 1; let generation = previewGeneration; phase = .previewing; error = nil
        start { [self] in
            do {
                let value = try await worker.preview(folder:folder)
                guard generation == previewGeneration, !Task.isCancelled, !disposed, !terminating else { phase = .idle; return }
                preview = value; phase = .awaitingConfirmation
            } catch { if generation == previewGeneration, !Task.isCancelled { self.error = error.localizedDescription; phase = .failed } else { phase = .idle } }
        }
    }
    func cancelPreview() {
        previewGeneration &+= 1
        if phase == .previewing { operation?.cancel() }
        if preview != nil { preview = nil; phase = .idle; changed() }
    }
    func confirmInstall() {
        guard canBegin, let value = preview else { return }
        preview = nil; phase = .stopping; error = nil; progress = nil
        start { [self] in await install(value) }
    }
    private func install(_ value: LocalVoiceEnginePreview) async {
        var candidate: LocalVoiceEngineCandidate?, passedProbe = false, activating = false
        do {
            guard await stopOutput() else { throw LocalVoiceError("语音尚未停止，请先重试停止再安装") }
            try Task.checkCancellation()
            candidate = try await worker.begin(value)
            phase = .copying; changed()
            try await worker.copy(candidate!) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.operation != nil, [.copying,.verifying].contains(self.phase) else { return }
                    self.progress = value; self.phase = value.phase == .copying ? .copying : .verifying; self.changed()
                }
            }
            try Task.checkCancellation(); phase = .probing; changed()
            _ = try await probe.run(configuration:candidate!.configuration,requestID:UUID())
            guard !probe.hasResources else { throw LocalVoiceError("自检资源尚未退出") }
            passedProbe = true; try Task.checkCancellation(); phase = .activating; changed(); activating = true
            _ = try await worker.activate(candidate!)
            // Store's descriptor rename is the commit point, including late cancel.
            candidate = nil; phase = .installed; error = nil; snapshot = await worker.current(); notifyActivated = true
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if let candidate {
                if activating && passedProbe && !cancelled {
                    pendingActivation = candidate; self.error = "引擎已自检，但尚未切换：\(error.localizedDescription)"; phase = .failed
                } else { await cleanup(candidate, failure:cancelled ? nil : error.localizedDescription) }
            } else { self.error = cancelled ? nil : error.localizedDescription; phase = cancelled ? .idle : .failed }
        }
        // A failed probe may still read candidate files. Keep EX until exit.
        if !probe.hasResources { await worker.releaseLease() }
    }
    private func cleanup(_ candidate:LocalVoiceEngineCandidate, failure:String?) async {
        cleanupPending = candidate
        guard await probe.stop(), !probe.hasResources else { error = "自检进程尚未确认退出；文件已保留，请重试停止与清理。"; phase = .failed; return }
        do { try await worker.discard(candidate); cleanupPending = nil; error = failure; phase = failure == nil ? .idle : .failed }
        catch { self.error = "未启用的引擎副本未能清理，可重试：\(error.localizedDescription)"; phase = .failed }
    }
    func checkCurrent() {
        guard canBegin, preview == nil else { return }
        phase = .checking; error = nil
        start { [self] in
            do {
                guard await stopOutput() else { throw LocalVoiceError("语音尚未停止，不能检查引擎") }
                try Task.checkCancellation(); snapshot = await worker.current()
                guard snapshot.configuration != nil else { throw LocalVoiceError("当前没有可检查的引擎，请选择引擎包安装或修复。") }
                try await worker.acquireLease(); snapshot = await worker.current()
                guard let configuration = snapshot.configuration else { throw LocalVoiceError("当前引擎已变化或不可用") }
                _ = try await probe.run(configuration:configuration,requestID:UUID()); try Task.checkCancellation()
                phase = .installed
            } catch { self.error = Task.isCancelled ? nil : error.localizedDescription; phase = Task.isCancelled ? .idle : .failed }
            if await probe.stop(), !probe.hasResources { await worker.releaseLease() }
            else { error = "自检尚未确认停止，请重试停止。"; phase = .failed }
        }
    }
    func cancelInstallation() {
        guard !disposed else { return }
        if let operation, phase != .previewing {
            operation.cancel(); phase = .cancelling
            if probe.hasResources, stopping == nil {
                stopping = Task { [self] in let result = await probe.stop(); stopping = nil; changed(); return result }
            }; changed()
        } else if operation == nil, let candidate = pendingActivation {
            pendingActivation = nil; phase = .cancelling
            start { [self] in await cleanup(candidate,failure:nil); if !probe.hasResources { await worker.releaseLease() } }
        }
    }
    func retryPending() { guard canRetry, !terminating, canStart() else { return }; retry() }
    private func retry() {
        error = nil; phase = .stopping
        start { [self] in
            if let candidate = cleanupPending { await cleanup(candidate,failure:nil) }
            else if let candidate = pendingActivation {
                do {
                    guard await stopOutput() else { throw LocalVoiceError("语音尚未停止，请重试停止") }
                    try Task.checkCancellation(); phase = .activating; changed()
                    _ = try await worker.activate(candidate)
                    pendingActivation = nil; phase = .installed; snapshot = await worker.current(); notifyActivated = true
                } catch {
                    if Task.isCancelled { pendingActivation = nil; await cleanup(candidate,failure:nil) }
                    else { self.error = error.localizedDescription; phase = .failed }
                }
            } else if !(await probe.stop()) { error = "自检尚未确认停止，请重试。"; phase = .failed }
            else { phase = .idle }
            if !probe.hasResources { await worker.releaseLease() }
        }
    }
    func beginTermination() { terminating = true; cancelPreview(); if operation != nil { cancelInstallation() } }
    func cancelTermination() { terminating = false; changed() }
    func waitForPending() async { await operation?.value; _ = await stopping?.value }
    func retryForTermination() async { guard !isBusy else { await waitForPending(); return }; if hasUnsaved || probe.hasResources { retry(); await waitForPending() } }
    func dispose() { guard !disposed else { return }; beginTermination(); disposed = true }
}
