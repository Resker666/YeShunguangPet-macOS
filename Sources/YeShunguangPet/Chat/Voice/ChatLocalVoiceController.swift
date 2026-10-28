import Foundation
import Combine
import PetCore

@MainActor final class ChatLocalVoiceController: ObservableObject {
    @Published private var changeRevision: UInt64 = 0
    private let persistence: any ChatPersisting, writes: ChatWriteQueue
    private let context: @MainActor () -> ChatCharacter?, canMutate: @MainActor () -> Bool, stopOutput: @MainActor () async -> Bool
    private(set) var index = LocalVoiceIndex(), entries = [LocalVoiceLibraryEntry]()
    private(set) var preview: StagedLocalVoice?
    private(set) var engineStatus: LocalVoiceEngineStatus = .unconfigured
    private(set) var error: String?, protection: String?
    private(set) var isLoaded = false
    private var disposed = false, terminating = false
    private var loadTask: Task<Void, Never>?, operationTask: Task<Void, Never>?, refreshTask: Task<Void, Never>?
    private var operationID: UUID?, previewOperation = false
    private var cleanupTasks = [UUID: Task<Void, Never>]()
    private var cleanup = Set<LocalVoiceCleanup>(), writing = 0
    private struct Pending { let mutation: LocalVoiceMutation; let expected: ChatCharacter? }
    private var pending: Pending?
    var isBusy: Bool { !isLoaded || operationTask != nil || refreshTask != nil || writing > 0 || !cleanupTasks.isEmpty }
    var hasPendingMutation: Bool { operationTask != nil || refreshTask != nil || writing > 0 || !cleanupTasks.isEmpty }
    var hasUnsaved: Bool { pending != nil || !cleanup.isEmpty }
    var terminationError: String? {
        guard hasUnsaved else { return nil }
        return error ?? "本地音色仍有未保存的更改或未清理文件，可重试本地保存与清理。"
    }
    init(persistence: any ChatPersisting, writes: ChatWriteQueue, context: @escaping @MainActor () -> ChatCharacter?, canMutate: @escaping @MainActor () -> Bool, stopOutput: @escaping @MainActor () async -> Bool) {
        self.persistence = persistence; self.writes = writes; self.context = context; self.canMutate = canMutate; self.stopOutput = stopOutput
        loadTask = Task { [weak self] in
            let result = await persistence.loadLocalVoiceIndex()
            let entries = await persistence.localVoiceEntries(), engine = await persistence.localVoiceEngineStatus()
            guard let self else { return }
            defer { self.loadTask = nil }
            guard !self.disposed else { return }
            switch result {
            case .missing: self.index = .init()
            case .loaded(let value): self.index = value
            case .protectedFile(let message): self.protection = message
            }
            self.entries = entries; self.engineStatus = engine; self.isLoaded = true; self.changeRevision &+= 1
        }
    }
    private var allowed: Bool { !disposed && !terminating && isLoaded && !isBusy && canMutate() }
    func refresh() {
        guard allowed else { return }
        refreshEntries()
    }
    private func refreshEntries() {
        refreshTask = Task { [self] in
            let entries = await persistence.localVoiceEntries(), engine = await persistence.localVoiceEngineStatus()
            self.entries = entries; engineStatus = engine; refreshTask = nil
            if !disposed { changeRevision &+= 1 }
        }
        if !disposed { changeRevision &+= 1 }
    }
    func preview(folder: URL) {
        guard allowed, protection == nil, !hasUnsaved, preview == nil else { return }
        let id = UUID(); operationID = id; previewOperation = true; error = nil
        operationTask = Task { [self] in
            do {
                let stopped = await stopOutput()
                guard operationID == id, !Task.isCancelled, !disposed, !terminating else { finishOperation(id); return }
                guard stopped, canMutate() else { error = LocalVoiceIssue.stopping.localizedDescription; finishOperation(id); return }
                let staged = try await persistence.stageLocalVoice(folder: folder)
                if Task.isCancelled || disposed || terminating || operationID != id { await discard(staged) }
                else { preview = staged }
            } catch { record(error) }
            finishOperation(id)
        }
        changeRevision &+= 1
    }
    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; operationTask = nil; previewOperation = false
        if !disposed { changeRevision &+= 1 }
    }
    private func record(_ failure: Error) {
        if let failure = failure as? LocalVoiceMutationError { cleanup.formUnion(failure.cleanupPending) }
        error = failure.localizedDescription
    }
    private func discard(_ staged: StagedLocalVoice) async {
        do { try await persistence.discardLocalVoiceStage(staged) }
        catch {
            cleanup.insert(.init(namespace: .staging, id: staged.stageID)); record(error)
        }
    }
    func cancelPreview() {
        if previewOperation { operationTask?.cancel() }
        guard let staged = preview else { return }
        preview = nil
        let token = UUID()
        cleanupTasks[token] = Task { [self] in
            await discard(staged); cleanupTasks[token] = nil
            if !disposed { changeRevision &+= 1 }
        }
        if !disposed { changeRevision &+= 1 }
    }
    func confirmImport() {
        guard allowed, protection == nil, pending == nil, let staged = preview else { return }
        if !index.packages.contains(where: { $0.contentID == staged.contentID }) {
            guard !index.packages.contains(where: { $0.packageID == staged.manifest.id }) else {
                error = "语音包 ID 已存在。请取消本次预览，再解除旧包绑定并删除旧副本后导入。"; changeRevision &+= 1; return
            }
            guard index.packages.count < 16 else {
                error = "语音库最多保留 16 个包。请取消预览并删除不用的副本后重试。"; changeRevision &+= 1; return
            }
        }
        preview = nil
        begin(.init(mutation: .install(staged), expected: nil))
    }
    func applyBinding(_ id: UUID?, expected: ChatCharacter) {
        guard allowed, protection == nil, !hasUnsaved, preview == nil, context() == expected else { return }
        if let id {
            guard index.packages.contains(where: { $0.id == id }),
                  entries.contains(where: { $0.registration.id == id && $0.issue == nil }) else {
                error = LocalVoiceIssue.voiceMissing.localizedDescription; changeRevision &+= 1; return
            }
        }
        begin(.init(mutation: .bind(characterID: expected.id, libraryID: id), expected: expected))
    }
    func delete(_ id: UUID) {
        guard allowed, protection == nil, !hasUnsaved, preview == nil else { return }
        guard !index.bindings.values.contains(id) else { error = "此音色仍被角色使用，请先取消绑定。"; changeRevision &+= 1; return }
        begin(.init(mutation: .remove(id), expected: nil))
    }
    func backupAndReset() {
        guard allowed, !hasUnsaved, preview == nil else { return }
        begin(.init(mutation: .reset, expected: nil))
    }
    func retryPendingSave() {
        guard allowed else { return }
        retry()
    }
    func retryPendingForTermination() {
        guard !disposed, isLoaded, !isBusy else { return }
        retry()
    }
    private func retry() {
        if let pending { begin(pending, retrying: true) }
        else if !cleanup.isEmpty { begin(.init(mutation: .retryCleanup(Array(cleanup)), expected: nil), retrying: true) }
    }
    private func begin(_ candidate: Pending, retrying: Bool = false) {
        let id = UUID(); operationID = id; previewOperation = false; pending = nil; error = nil
        operationTask = Task { [self] in
            let stopped = await stopOutput()
            guard operationID == id else { return }
            // A retry persists an already accepted transaction for its frozen
            // role ID. Changing the visible role cannot discard that intent.
            if !retrying, let expected = candidate.expected, context() != expected {
                error = "角色已改变，音色绑定未应用。请重新选择当前角色。"; finishOperation(id); return
            }
            guard stopped else {
                pending = candidate; error = LocalVoiceIssue.stopping.localizedDescription; finishOperation(id); return
            }
            // Once confirmed, closing the host does not revoke an accepted local
            // transaction. New unconfirmed work is still rejected by the gates.
            guard retrying || terminating || disposed || canMutate() else {
                pending = candidate; error = "当前窗口状态阻止保存，已确认的更改可重试。"; finishOperation(id); return
            }
            operationID = nil; operationTask = nil; writing += 1
            writes.enqueue(.localVoice(candidate.mutation)) { [self] _, result in
                writing -= 1
                switch result {
                case .success(.localVoice(let commit)):
                    index = commit.index; protection = nil; pending = nil
                    if case .retryCleanup(let attempted) = candidate.mutation { cleanup.subtract(attempted) }
                    cleanup.formUnion(commit.cleanupPending)
                    error = cleanup.isEmpty ? nil : "更改已保存，仍有文件未清理；可重试本地清理。"
                    refreshEntries()
                case .failure(let failure):
                    if case .retryCleanup = candidate.mutation {} else { pending = candidate }
                    record(failure)
                default:
                    pending = candidate; error = "语音库未能保存，请重试本地保存。"
                }
                if !disposed { changeRevision &+= 1 }
            }
            if !disposed { changeRevision &+= 1 }
        }
        if !disposed { changeRevision &+= 1 }
    }
    func resolve(for character: ChatCharacter) async -> VoiceRouteSelection {
        if let loadTask { await loadTask.value }
        guard !disposed, !terminating, context() == character else { return .unavailable(.cancelled) }
        guard protection == nil, isLoaded else { return .unavailable(.libraryProtected) }
        guard let id = index.binding(for: character.id) else { return .system }
        let engine = await persistence.localVoiceEngineStatus()
        guard !disposed, !terminating, context() == character else { return .unavailable(.cancelled) }
        guard case .configured = engine else { return .unavailable(.engineUnconfigured) }
        do {
            let resolved = try await persistence.resolveLocalVoice(libraryID: id)
            guard !disposed, !terminating, context() == character else { return .unavailable(.cancelled) }
            return .local(resolved)
        } catch { return .unavailable(.voiceMissing) }
    }
    func beginTermination() { terminating = true; cancelPreview() }
    func cancelTermination() { guard !disposed else { return }; terminating = false; changeRevision &+= 1 }
    func waitForPendingMutations() async {
        while true {
            if let operationTask { await operationTask.value }
            for task in cleanupTasks.values { await task.value }
            await writes.waitForPending()
            if let refreshTask { await refreshTask.value }
            if !hasPendingMutation { return }
        }
    }
    func dispose() { guard !disposed else { return }; cancelPreview(); disposed = true; terminating = true }
}
