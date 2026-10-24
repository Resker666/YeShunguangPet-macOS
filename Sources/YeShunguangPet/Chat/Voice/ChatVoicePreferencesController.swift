import Foundation
import Combine
import PetCore

@MainActor final class ChatVoicePreferencesController: ObservableObject {
    // Publish after complete intent transitions; subscribers may synchronously disable.
    @Published private var changeRevision: UInt64 = 0
    private(set) var preferences = VoicePreferences()
    private(set) var isLoaded = false
    private(set) var error: String?, protection: String?
    private var temporaryDisable = false, disposed = false
    private var intent: UInt64 = 0, writeCount = 0
    private struct Pending { let value: VoicePreferences; let reset: Bool }
    private var pending: Pending?
    private let writes: ChatWriteQueue
    private let canMutate: () -> Bool
    private var loadTask: Task<Void, Never>?
    var onDisable: (() -> Void)?
    var enabledForSession: Bool { isLoaded && !disposed && protection == nil && !temporaryDisable && preferences.enabled }
    var isWriting: Bool { writeCount > 0 }
    var hasUnsaved: Bool { pending != nil }
    init(persistence: any ChatPersisting, writes: ChatWriteQueue, canMutate: @escaping () -> Bool = { true }) {
        self.writes = writes; self.canMutate = canMutate
        loadTask = Task { [weak self] in
            let result = await persistence.loadVoicePreferences()
            guard let self, !self.disposed, !Task.isCancelled else { return }
            switch result {
            case .missing: self.preferences = .init()
            case .loaded(let value): self.preferences = value
            case .protectedFile(let message): self.protection = message
            }
            self.isLoaded = true; self.loadTask = nil; self.changeRevision &+= 1
        }
    }
    func apply(_ value: VoicePreferences) {
        guard !disposed, isLoaded, canMutate(), !disposed, protection == nil, !isWriting else { return }
        do { try value.validate() } catch { self.error = "语音设置无效，请检查音色和语速。"; changeRevision &+= 1; return }
        if !value.enabled {
            temporaryDisable = true
            enqueue(.init(value: value, reset: false), explicitEnable: false, notify: false)
            onDisable?(); changeRevision &+= 1; return
        }
        enqueue(.init(value: value, reset: false), explicitEnable: true)
    }
    func disable() {
        guard !disposed, isLoaded, canMutate(), !disposed else { return }
        temporaryDisable = true
        var value = preferences; value.enabled = false
        if protection == nil { enqueue(.init(value: value, reset: false), explicitEnable: false, notify: false) }
        onDisable?(); changeRevision &+= 1
    }
    func retryPendingSave() {
        guard !disposed, canMutate(), !isWriting, let pending else { return }
        enqueue(pending, explicitEnable: false)
    }
    func discardPendingSave() {
        guard !disposed, canMutate(), !isWriting else { return }
        pending = nil; error = nil; changeRevision &+= 1
    }
    func backupAndReset() {
        guard !disposed, isLoaded, canMutate(), !isWriting else { return }
        temporaryDisable = true
        enqueue(.init(value: .init(), reset: true), explicitEnable: false, notify: false)
        onDisable?(); changeRevision &+= 1
    }
    private func enqueue(_ candidate: Pending, explicitEnable: Bool, notify: Bool = true) {
        intent &+= 1; let current = intent
        writeCount += 1; pending = nil; error = nil
        writes.enqueue(candidate.reset ? .resetVoicePreferences : .voicePreferences(candidate.value)) { [weak self] _, result in
            guard let self else { return }
            self.writeCount -= 1
            guard current == self.intent else { self.changeRevision &+= 1; return }
            switch result {
            case .success(.voicePreferences(let saved)):
                self.preferences = saved; self.protection = nil; self.pending = nil; self.error = nil
                if explicitEnable && saved.enabled && !self.disposed { self.temporaryDisable = false }
            default:
                self.pending = candidate
                self.error = candidate.reset ? "语音设置未能备份并重置，原文件仍受保护。" : "语音偏好尚未保存，可重试本地保存；本次关闭仍生效，重开可能恢复旧偏好。"
            }
            self.changeRevision &+= 1
        }
        if notify { changeRevision &+= 1 }
    }
    func dispose() { guard !disposed else { return }; disposed = true; temporaryDisable = true; loadTask?.cancel(); loadTask = nil; onDisable?(); onDisable = nil }
}
