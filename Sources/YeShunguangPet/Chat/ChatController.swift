import Foundation
import Combine
import PetCore

struct ChatCharacter: Equatable, Sendable {
    let id, name, description: String
    let skinRevision: UInt64
}
enum ChatState: Equatable { case idle, loading, readingCredential, streaming, saving, unsaved, failed }

@MainActor final class ChatController: NSObject, ObservableObject {
    private struct PendingPair {
        let token = UUID()
        let user, assistant, originalDraft: String
    }
    private enum CredentialAvailability { case unknown, available, missing }
    @Published private(set) var character: ChatCharacter?
    @Published private(set) var conversation: ChatConversation?
    @Published private(set) var draft = ""
    @Published private(set) var partialReply = ""
    @Published private(set) var state = ChatState.loading
    @Published private(set) var connection = ChatConnection()
    @Published private(set) var connectionLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var credentialFeedback: String?
    @Published private(set) var credentialMutationError: String?
    @Published private(set) var credentialSavedRevision: UInt64 = 0
    @Published private(set) var profileEditRevision: UInt64 = 0

    let persistence: any ChatPersisting
    private let credentials: any ChatCredentialStoring
    private let client: any ChatStreaming
    private let canDispatch: () -> Bool
    private let onFeedback: (String) -> Void
    private let writes: ChatWriteQueue
    private var archives = [String: ChatConversation](), drafts = [String: String](), partials = [String: String]()
    private var provisionalInputs = [String:String]()
    var currentProvisionalInput: String? { character.flatMap { provisionalInputs[$0.id] } }
    private var protectedRoles = [String: String](), roleErrors = [String: String]()
    private var pendingPairs = [String: PendingPair](), roleWrites = [String: Int](), lastReceipts = [String: UInt64]()
    private(set) var connectionProtection: String?
    private var pendingConnection: ChatConnection?
    private var connectionWriteCount = 0
    private var connectionGeneration: UInt64 = 0
    private var connectionWriting: Bool { connectionWriteCount > 0 }
    private var credentialAvailability = CredentialAvailability.unknown
    private var requestTask: Task<Void, Never>?, roleLoadTask: Task<Void, Never>?, connectionLoadTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?, flushTask: Task<Void, Never>?
    private var generation: UInt64 = 0, activationGeneration: UInt64 = 0
    private var activeRequest: ChatCharacter?, readingCredential = false
    private(set) var sleeping = false
    private(set) var terminating = false
    private(set) var disposed = false
    private var presented = false

    var unsavedCharacterIDs: [String] { pendingPairs.keys.sorted() }
    var hasPendingWrites: Bool { writes.hasPending || credentialTask != nil }
    var isGenerating: Bool { requestTask != nil }
    var canEditProfile: Bool {
        guard let id = character?.id else { return false }
        return canMutate && activeRequest == nil && archives[id] != nil && protectedRoles[id] == nil
            && pendingPairs[id] == nil && roleWrites[id, default: 0] == 0
    }
    var canChangeConnection: Bool { canMutate && !isGenerating && !connectionWriting && credentialTask == nil && connectionLoaded }
    var canSend: Bool {
        guard let id = character?.id else { return false }
        return canMutate && connectionLoaded && connection.enabled && connectionProtection == nil
            && connectionError == nil && !connectionWriting && credentialTask == nil && credentialMutationError == nil
            && credentialAvailability != .missing && requestTask == nil && archives[id] != nil
            && protectedRoles[id] == nil && pendingPairs[id] == nil && roleWrites[id, default: 0] == 0
            && (try? ChatText.validate(draft, maxUTF16: 2000, allowEmpty: false)) != nil
    }
    var canClearHistory: Bool { canMutate && character.flatMap { archives[$0.id] } != nil && character.flatMap { protectedRoles[$0.id] } == nil }
    var currentArchiveProtection: String? { character.flatMap { protectedRoles[$0.id] } }
    var canRetryPendingSave: Bool { canMutate && character.map { pendingPairs[$0.id] != nil && roleWrites[$0.id, default: 0] == 0 } == true }
    var canRetryConnectionSave: Bool { canChangeConnection && pendingConnection != nil }
    var canRetryTerminationSave: Bool { !pendingPairs.isEmpty || pendingConnection != nil }
    var terminationSaveError: String? {
        if !pendingPairs.isEmpty { return "有 \(pendingPairs.count) 个角色的完整对话尚未保存。" }
        return connectionError ?? credentialMutationError
    }
    private var canMutate: Bool { !disposed && !terminating && !sleeping && canDispatch() }

    init(persistence: any ChatPersisting, credentials: any ChatCredentialStoring, client: any ChatStreaming,
         canDispatch: @escaping () -> Bool, onFeedback: @escaping (String) -> Void) {
        self.persistence = persistence; self.credentials = credentials; self.client = client
        self.canDispatch = canDispatch; self.onFeedback = onFeedback
        writes = ChatWriteQueue(persistence: persistence)
        super.init()
        startLifecycleObservers()
        connectionLoadTask = Task { [weak self, persistence] in
            let result = await persistence.loadConnection()
            guard let self, !self.disposed, !Task.isCancelled else { return }
            switch result {
            case .missing: self.connection = .init()
            case .loaded(let value): self.connection = value
            case .protectedFile(let message): self.connectionProtection = message
            }
            self.connectionLoaded = true; self.connectionLoadTask = nil; self.refreshCurrent()
        }
    }

    func activate(_ value: ChatCharacter) {
        guard !disposed else { return }
        if character == value { refreshCurrent(); return }
        cancelRequest()
        roleLoadTask?.cancel()
        activationGeneration &+= 1
        let activation = activationGeneration
        character = value; profileEditRevision &+= 1
        if archives[value.id] != nil || protectedRoles[value.id] != nil { refreshCurrent(); return }
        refreshCurrent()
        let persistence = persistence
        roleLoadTask = Task { [weak self] in
            let initial = ChatProfile(background: value.description)
            let result = await persistence.loadCharacter(id: value.id, defaultProfile: initial)
            guard let self, !self.disposed, !Task.isCancelled, self.activationGeneration == activation else { return }
            switch result {
            case .missing:
                do { self.archives[value.id] = try ChatConversation(characterID: value.id, profile: initial) }
                catch { self.protectedRoles[value.id] = "角色聊天初始资料无效。" }
            case .loaded(let archive): self.archives[value.id] = archive
            case .protectedFile(let message): self.protectedRoles[value.id] = message
            }
            self.roleLoadTask = nil; self.profileEditRevision &+= 1; self.refreshCurrent()
        }
    }

    func setDraft(_ text: String) {
        guard !disposed, let id = character?.id else { return }
        drafts[id] = text; draft = text
    }

    func send() {
        guard canSend, let context = character, let archive = archives[context.id] else { return }
        let snapshot: ChatPromptSnapshot
        do {
            snapshot = try .init(characterID: context.id, characterName: context.name, conversation: archive, model: connection.model, input: draft)
        } catch { roleErrors[context.id] = "输入或人设无效，请检查后再发送。"; refreshCurrent(); return }
        generation &+= 1
        let current = generation, original = draft, input = snapshot.messages.last!.content
        activeRequest = context; readingCredential = true; provisionalInputs[context.id] = input
        roleErrors[context.id] = nil; partials[context.id] = ""
        let credentials = credentials, client = client
        requestTask = Task { [weak self] in
            do {
                guard let key = try await credentials.read() else {
                    guard let self, self.isCurrent(current, context) else { return }
                    self.credentialAvailability = .missing
                    self.failRequest("尚未保存 API 密钥，请到连接页填写。", context: context)
                    return
                }
                guard let self, self.isCurrent(current, context), !Task.isCancelled else { return }
                self.credentialAvailability = .available; self.readingCredential = false; self.refreshCurrent()
                var answer = ""
                for try await event in client.stream(snapshot, apiKey: key) {
                    guard self.isCurrent(current, context), !Task.isCancelled else { return }
                    switch event {
                    case .delta(let text):
                        guard answer.utf16.count + text.utf16.count <= 8000 else { throw SkinError("AI 回复超长，未记入记录。") }
                        answer += text; self.partials[context.id] = answer
                        self.scheduleFlush()
                    case .completed:
                        try ChatText.validate(answer, maxUTF16: 8000, allowEmpty: false)
                        self.requestTask = nil; self.activeRequest = nil; self.readingCredential = false
                        self.flushTask?.cancel(); self.flushTask = nil
                        let pair = PendingPair(user: input, assistant: answer, originalDraft: original)
                        self.pendingPairs[context.id] = pair
                        self.enqueuePair(pair, id: context.id, feedback: (current, context))
                        return
                    }
                }
                throw SkinError("AI 连接提前结束，未记入记录。")
            } catch {
                guard let self, self.isCurrent(current, context), !Task.isCancelled else { return }
                let message = (error as? SkinError)?.message ?? "AI 请求未完成，可手动重试。"
                self.failRequest(message, context: context)
            }
        }
        refreshCurrent()
    }

    private func isCurrent(_ request: UInt64, _ context: ChatCharacter) -> Bool {
        !disposed && !terminating && !sleeping && generation == request && character == context && activeRequest == context
    }
    private func failRequest(_ message: String, context: ChatCharacter) {
        requestTask = nil; activeRequest = nil; readingCredential = false
        flushTask?.cancel(); flushTask = nil
        roleErrors[context.id] = message; refreshCurrent()
    }
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self, !self.disposed, !Task.isCancelled else { return }
            self.flushTask = nil; self.refreshCurrent()
        }
    }
    private func cancelRequest() {
        generation &+= 1
        requestTask?.cancel(); requestTask = nil
        flushTask?.cancel(); flushTask = nil
        if let context = activeRequest { roleErrors[context.id] = "已停止，本次未完成回复未记入历史。" }
        activeRequest = nil; readingCredential = false
    }
    func stop() { guard !disposed else { return }; cancelRequest(); refreshCurrent() }

    private func enqueueCharacter(_ operation: ChatWriteOperation, id: String, completion: @escaping (Result<ChatConversation, Error>) -> Void) {
        roleWrites[id, default: 0] += 1
        writes.enqueue(operation) { [weak self] ticket, result in
            guard let self else { return }
            self.roleWrites[id, default: 0] -= 1
            guard ticket.sequence > self.lastReceipts[id, default: 0] else { return }
            self.lastReceipts[id] = ticket.sequence
            switch result {
            case .success(.character(let value)) where value.characterID == id:
                self.archives[id] = value
                completion(.success(value))
            case .success: completion(.failure(SkinError("聊天保存结果与角色不匹配。")))
            case .failure(let error): completion(.failure(error))
            }
            self.refreshCurrent()
        }
        refreshCurrent()
    }

    private func enqueuePair(_ pair: PendingPair, id: String, feedback: (UInt64, ChatCharacter)?) {
        enqueueCharacter(.append(characterID: id, user: pair.user, assistant: pair.assistant), id: id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.pendingPairs[id]?.token == pair.token {
                    self.pendingPairs[id] = nil; self.partials[id] = nil; self.provisionalInputs[id] = nil; self.roleErrors[id] = nil
                    if self.drafts[id] == pair.originalDraft { self.drafts[id] = "" }
                }
                if let (request, context) = feedback, !self.disposed, !self.terminating, !self.sleeping,
                   self.generation == request, self.character == context {
                    self.onFeedback(pair.assistant)
                }
            case .failure:
                self.roleErrors[id] = "本次对话尚未保存，可重试本地保存或明确丢弃。"
            }
        }
    }

    func retryPendingSave() {
        guard canRetryPendingSave, let id = character?.id, let pair = pendingPairs[id] else { return }
        enqueuePair(pair, id: id, feedback: nil)
    }
    func discardPendingSave() {
        guard canRetryPendingSave, let id = character?.id else { return }
        pendingPairs[id] = nil; partials[id] = nil; provisionalInputs[id] = nil; roleErrors[id] = nil; refreshCurrent()
    }
    func applyProfile(_ profile: ChatProfile) { if let context = character { applyProfile(profile, for: context) } }
    func applyProfile(_ profile: ChatProfile, for context: ChatCharacter) {
        guard canEditProfile, character == context else { return }
        do { try profile.validate() } catch { roleErrors[context.id] = "人设过长或含有无效文字。"; refreshCurrent(); return }
        enqueueCharacter(.profile(characterID: context.id, profile: profile), id: context.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.roleErrors[context.id] = nil
                if self.character == context { self.profileEditRevision &+= 1 }
            case .failure: self.roleErrors[context.id] = "人设未保存，原人设保持不变。"
            }
        }
    }
    func clearHistory() { if let context = character { clearHistory(for: context) } }
    func clearHistory(for context: ChatCharacter) {
        guard canClearHistory, character == context else { return }
        cancelRequest()
        enqueueCharacter(.clear(characterID: context.id), id: context.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.pendingPairs[context.id] = nil; self.partials[context.id] = nil; self.provisionalInputs[context.id] = nil; self.roleErrors[context.id] = nil
            case .failure: self.roleErrors[context.id] = "记录未能清空，原历史与待存结果保留。"
            }
        }
    }
    func resetCharacterArchive() {
        guard canMutate, let context = character, roleWrites[context.id, default: 0] == 0 else { return }
        cancelRequest()
        enqueueCharacter(.reset(characterID: context.id, profile: .init(background: context.description)), id: context.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.protectedRoles[context.id] = nil; self.roleErrors[context.id] = nil; self.pendingPairs[context.id] = nil; self.partials[context.id] = nil; self.provisionalInputs[context.id] = nil
                if self.character == context { self.profileEditRevision &+= 1 }
            case .failure: self.roleErrors[context.id] = "记录未能备份并重置，原资料保持不变。"
            }
        }
    }

    func saveConnection(_ value: ChatConnection) {
        guard canMutate, connectionLoaded else { return }
        if !value.enabled {
            // Disabling is a new intent even while an older preference/key write is pending.
            cancelRequest(); connection.enabled = false
        } else if connectionWriting || credentialTask != nil || isGenerating { refreshCurrent(); return }
        guard connectionProtection == nil else { refreshCurrent(); return }
        enqueueConnection(value)
    }
    private func enqueueConnection(_ value: ChatConnection) {
        connectionGeneration &+= 1
        let intent = connectionGeneration
        connectionWriteCount += 1
        writes.enqueue(.connection(value)) { [weak self] _, result in
            guard let self else { return }
            self.connectionWriteCount -= 1
            // FIFO still commits every accepted write, but an old receipt cannot undo newer UI intent.
            guard intent == self.connectionGeneration else { self.refreshCurrent(); return }
            switch result {
            case .success(.connection(let saved)):
                self.connection = saved; self.connectionError = nil; self.pendingConnection = nil
            case .success: self.connectionError = "AI 连接保存结果无效。"; self.pendingConnection = value
            case .failure: self.connectionError = "AI 连接偏好未保存，可重试保存。"; self.pendingConnection = value
            }
            self.refreshCurrent()
        }
        refreshCurrent()
    }
    func retryConnectionSave() {
        guard canRetryConnectionSave, let value = pendingConnection else { return }
        enqueueConnection(value)
    }
    func resetConnectionArchive() {
        guard canMutate, !isGenerating, !connectionWriting else { return }
        connectionGeneration &+= 1
        let intent = connectionGeneration
        connectionWriteCount += 1
        writes.enqueue(.resetConnection) { [weak self] _, result in
            guard let self else { return }
            self.connectionWriteCount -= 1
            guard intent == self.connectionGeneration else { self.refreshCurrent(); return }
            switch result {
            case .success(.connection(let value)):
                self.connection = value; self.connectionProtection = nil; self.connectionError = nil; self.pendingConnection = nil
            default: self.connectionError = "AI 连接未能备份并重置。"
            }
            self.refreshCurrent()
        }
        refreshCurrent()
    }

    func saveCredential(_ secret: String) {
        guard canMutate, !isGenerating, credentialTask == nil else { return }
        let normalized: String
        do { normalized = try ChatSecret.normalize(secret) }
        catch { credentialMutationError = "API 密钥为空、过长或含有无效字符。"; refreshCurrent(); return }
        credentialFeedback = nil; credentialMutationError = nil
        let credentials = credentials
        credentialTask = Task { [weak self] in
            let failure: String?
            do { try await credentials.save(normalized); failure = nil }
            catch { failure = (error as? SkinError)?.message ?? "API 密钥未能保存，请重试。" }
            guard let self else { return }
            self.credentialTask = nil; self.credentialMutationError = failure
            if failure == nil {
                self.credentialAvailability = .available; self.credentialFeedback = "API 密钥已保存到钥匙串。"; self.credentialSavedRevision &+= 1
            }
            self.refreshCurrent()
        }
        refreshCurrent()
    }
    func removeCredential() {
        guard canMutate, !isGenerating, credentialTask == nil else { return }
        credentialFeedback = nil; credentialMutationError = nil
        let credentials = credentials
        credentialTask = Task { [weak self] in
            let failure: String?
            do { try await credentials.remove(); failure = nil }
            catch { failure = (error as? SkinError)?.message ?? "API 密钥未能移除，请重试。" }
            guard let self else { return }
            self.credentialTask = nil; self.credentialMutationError = failure
            if failure == nil { self.credentialAvailability = .missing; self.credentialFeedback = "已移除本 App 的 API 密钥。" }
            self.refreshCurrent()
        }
        refreshCurrent()
    }

    func setPresented(_ presented: Bool) { self.presented = presented }
    func windowClosed() { cancelRequest(); presented = false; profileEditRevision &+= 1; refreshCurrent() }
    func setSleeping(_ sleeping: Bool) {
        guard !disposed, self.sleeping != sleeping else { return }
        self.sleeping = sleeping
        if sleeping { cancelRequest() }
        refreshCurrent()
    }
    func beginTermination() { guard !disposed else { return }; terminating = true; cancelRequest(); refreshCurrent() }
    func cancelTermination() { guard !disposed else { return }; terminating = false; refreshCurrent() }
    func waitForPendingWrites() async {
        while true {
            if let credentialTask { await credentialTask.value }
            await writes.waitForPending()
            if credentialTask == nil && !writes.hasPending { return }
        }
    }
    func retryAllPendingSaves() async -> Bool {
        guard !disposed else { return false }
        await waitForPendingWrites()
        for (id, pair) in pendingPairs { enqueuePair(pair, id: id, feedback: nil) }
        if let value = pendingConnection, !connectionWriting { enqueueConnection(value) }
        await waitForPendingWrites()
        return terminationSaveError == nil
    }
    func dispose() {
        guard !disposed else { return }
        cancelRequest(); disposed = true; presented = false
        roleLoadTask?.cancel(); connectionLoadTask?.cancel()
        stopLifecycleObservers()
    }

    private func refreshCurrent() {
        guard !disposed else { return }
        let id = character?.id
        conversation = id.flatMap { archives[$0] }
        draft = id.flatMap { drafts[$0] } ?? ""
        partialReply = id.flatMap { partials[$0] } ?? ""
        error = id.flatMap { roleErrors[$0] ?? protectedRoles[$0] } ?? connectionProtection ?? connectionError ?? credentialMutationError
        if !connectionLoaded || (id != nil && conversation == nil && currentArchiveProtection == nil) { state = .loading }
        else if activeRequest != nil { state = readingCredential ? .readingCredential : .streaming }
        else if id.map({ roleWrites[$0, default: 0] > 0 }) == true { state = .saving }
        else if id.flatMap({ pendingPairs[$0] }) != nil { state = .unsaved }
        else { state = error == nil ? .idle : .failed }
    }
}
