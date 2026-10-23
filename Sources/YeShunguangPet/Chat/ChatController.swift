import Foundation
import Combine
import PetCore

struct ChatCharacter: Equatable, Sendable {
    let id, name, description: String
    let skinRevision: UInt64
}
enum ChatState: Equatable { case idle, loading, readingCredential, streaming, extractingMemories, awaitingAction, saving, unsaved, unsavedMemory, failed }

@MainActor final class ChatController: NSObject, ObservableObject {
    private struct PendingPair {
        enum Kind { case modelReply, actionReceipt(ChatActionReceipt.Outcome) }
        let token = UUID()
        let user, assistant, originalDraft: String
        var kind: Kind = .modelReply
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
    @Published private(set) var memoryEditRevision: UInt64 = 0
    @Published private(set) var memoryReview: MemoryReviewState?

    @Published private(set) var pendingAction: ChatActionProposal?
    private var executingAction: ChatActionProposal?
    private let actions: any ChatActionExecuting

    let persistence: any ChatPersisting
    private let credentials: any ChatCredentialStoring
    private let client: any ChatStreaming
    private let memoryClient: any ChatMemoryExtracting
    private let canDispatch: () -> Bool
    private let onFeedback: (String) -> Void
    private let writes: ChatWriteQueue
    private var archives = [String: ChatConversation](), drafts = [String: String](), partials = [String: String]()
    private var provisionalInputs = [String:String]()
    var currentProvisionalInput: String? { character.flatMap { provisionalInputs[$0.id] } }
    private var protectedRoles = [String: String](), roleErrors = [String: String]()
    private var pendingPairs = [String: PendingPair](), roleWrites = [String: Int](), lastReceipts = [String: UInt64]()
    private var pendingMemories = [String: PendingMemoryChange]()
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
    private var activeRequestKind: ChatRequestKind?
    private(set) var sleeping = false
    private(set) var terminating = false
    private(set) var disposed = false
    private var presented = false

    var unsavedCharacterIDs: [String] { pendingPairs.keys.sorted() }
    var pendingMemoryCharacterIDs: [String] { pendingMemories.keys.sorted() }
    var hasPendingWrites: Bool { writes.hasPending || credentialTask != nil || executingAction != nil }
    var isGenerating: Bool { requestTask != nil }
    var isGeneratingConversation: Bool { activeRequestKind == .conversation && isGenerating }
    var isExtractingMemories: Bool { activeRequestKind == .memoryExtraction }
    var canExtractMemories: Bool {
        guard canEditMemories, let archive = conversation else { return false }
        return memoryReview == nil && !archive.messages.isEmpty && archive.memories.count < 20
            && connectionLoaded && connection.enabled && connectionProtection == nil && connectionError == nil
            && !connectionWriting && credentialTask == nil && credentialMutationError == nil && credentialAvailability != .missing
    }
    var canEditProfile: Bool {
        guard let id = character?.id else { return false }
        return canMutate && pendingAction == nil && executingAction == nil && activeRequest == nil && archives[id] != nil && protectedRoles[id] == nil
            && pendingPairs[id] == nil && pendingMemories[id] == nil && roleWrites[id, default: 0] == 0
    }
    var canEditMemories: Bool { canEditProfile }
    var canRetryMemorySave: Bool {
        canMutate && activeRequest == nil && character.map { pendingMemories[$0.id] != nil && roleWrites[$0.id, default: 0] == 0 } == true
    }
    var canChangeConnection: Bool { canMutate && pendingAction == nil && executingAction == nil && !isGenerating && !connectionWriting && credentialTask == nil && connectionLoaded }
    var canSend: Bool {
        guard let id = character?.id else { return false }
        return canMutate && pendingAction == nil && executingAction == nil && connectionLoaded && connection.enabled && connectionProtection == nil
            && connectionError == nil && !connectionWriting && credentialTask == nil && credentialMutationError == nil
            && credentialAvailability != .missing && requestTask == nil && archives[id] != nil
            && protectedRoles[id] == nil && pendingPairs[id] == nil && pendingMemories[id] == nil && roleWrites[id, default: 0] == 0
            && (try? ChatText.validate(draft, maxUTF16: 2000, allowEmpty: false)) != nil
    }
    var canClearHistory: Bool { canMutate && executingAction == nil && character.flatMap { archives[$0.id] } != nil && character.flatMap { protectedRoles[$0.id] } == nil && character.flatMap { pendingMemories[$0.id] } == nil }
    var currentArchiveProtection: String? { character.flatMap { protectedRoles[$0.id] } }
    var canRetryPendingSave: Bool { canMutate && character.map { pendingPairs[$0.id] != nil && roleWrites[$0.id, default: 0] == 0 } == true }
    var canRetryConnectionSave: Bool { canChangeConnection && pendingConnection != nil }
    var canRetryTerminationSave: Bool { !pendingPairs.isEmpty || !pendingMemories.isEmpty || pendingConnection != nil }
    var terminationSaveError: String? {
        var messages = [String]()
        if executingAction != nil { messages.append("操作正在执行，回执尚未保存。") }
        if !pendingPairs.isEmpty { messages.append("有 \(pendingPairs.count) 个角色的完整对话尚未保存。") }
        if !pendingMemories.isEmpty { messages.append("有 \(pendingMemories.count) 个角色的已确认记忆变更尚未保存。") }
        if let connectionError { messages.append(connectionError) }
        if let credentialMutationError { messages.append(credentialMutationError) }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    private var canMutate: Bool { !disposed && !terminating && !sleeping && canDispatch() }

    init(persistence: any ChatPersisting, credentials: any ChatCredentialStoring, client: any ChatStreaming, memoryClient: any ChatMemoryExtracting, actions: any ChatActionExecuting,
         canDispatch: @escaping () -> Bool, onFeedback: @escaping (String) -> Void) {
        self.persistence = persistence; self.credentials = credentials; self.client = client
        self.memoryClient = memoryClient; self.actions = actions
        self.canDispatch = canDispatch; self.onFeedback = onFeedback
        writes = ChatWriteQueue(persistence: persistence)
        super.init()
        actions.onChange = { [weak self] in self?.refreshActionAvailability() }
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
        memoryReview = nil
        cancelRequest()
        roleLoadTask?.cancel()
        activationGeneration &+= 1
        let activation = activationGeneration
        character = value; profileEditRevision &+= 1; memoryEditRevision &+= 1
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
            self.roleLoadTask = nil; self.profileEditRevision &+= 1; self.memoryEditRevision &+= 1; self.refreshCurrent()
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
            let runtime = actions.snapshot()
            guard canSend, character == context else { return }
            snapshot = try .init(characterID: context.id, characterName: context.name, conversation: archive, model: connection.model, input: draft, appSnapshot: runtime)
        } catch { roleErrors[context.id] = "输入或人设无效，请检查后再发送。"; refreshCurrent(); return }
        generation &+= 1
        let current = generation, connectionEpoch = connectionGeneration, original = draft, input = snapshot.messages.last!.content
        activeRequest = context; activeRequestKind = .conversation; readingCredential = true; provisionalInputs[context.id] = input
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
                    case .action(let action):
                        let expected = self.actions.snapshot()
                        guard self.isCurrent(current, context), self.connectionGeneration == connectionEpoch else { return }
                        self.requestTask = nil; self.activeRequest = nil; self.activeRequestKind = nil; self.readingCredential = false
                        self.flushTask?.cancel(); self.flushTask = nil; self.partials[context.id] = nil
                        self.pendingAction = .init(id: UUID(), context: context, requestGeneration: current, connectionGeneration: connectionEpoch, originalDraft: original, userInput: input, action: action, expectedSnapshot: expected)
                        // A Published subscriber can synchronously close/switch the host.
                        if self.generation != current || self.character != context || self.terminating || self.sleeping || self.disposed { self.pendingAction = nil }
                        self.refreshCurrent()
                        return
                    case .completed:
                        try ChatText.validate(answer, maxUTF16: 8000, allowEmpty: false)
                        self.requestTask = nil; self.activeRequest = nil; self.activeRequestKind = nil; self.readingCredential = false
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
        requestTask = nil; activeRequest = nil; activeRequestKind = nil; readingCredential = false
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
        if let card = pendingAction { roleErrors[card.context.id] = "操作提议已失效，未执行；可重新发送。" }
        pendingAction = nil
        generation &+= 1
        requestTask?.cancel(); requestTask = nil
        flushTask?.cancel(); flushTask = nil
        if let context = activeRequest { roleErrors[context.id] = activeRequestKind == .memoryExtraction ? "已停止提炼，未保存记忆。" : "已停止，本次未完成回复未记入历史。" }
        activeRequest = nil; activeRequestKind = nil; readingCredential = false
    }
    func stop() { guard !disposed else { return }; cancelRequest(); refreshCurrent() }

    var canDecideAction: Bool {
        guard let card = pendingAction, let context = character else { return false }
        return canMutate && executingAction == nil && card.context == context && card.requestGeneration == generation
            && card.connectionGeneration == connectionGeneration && connection.enabled && !connectionWriting && credentialTask == nil
            && activeRequest == nil && pendingPairs[context.id] == nil && pendingMemories[context.id] == nil && roleWrites[context.id, default: 0] == 0
    }
    func refreshActionAvailability() {
        guard let card = pendingAction, executingAction == nil else { return }
        let current = actions.snapshot()
        guard pendingAction?.id == card.id else { return }
        if current.commandStamp != card.expectedSnapshot.commandStamp {
            pendingAction = nil
            roleErrors[card.context.id] = "专注或安静状态已经变化，操作提议已失效，未执行。请重新发送。"
        }
        refreshCurrent()
    }
    func confirmAction(id: UUID, for context: ChatCharacter) { decideAction(id: id, context: context, cancel: false) }
    func cancelAction(id: UUID, for context: ChatCharacter) { decideAction(id: id, context: context, cancel: true) }
    private func decideAction(id: UUID, context: ChatCharacter, cancel: Bool) {
        guard canDecideAction, let card = pendingAction, card.id == id, card.context == context,
              provisionalInputs[context.id] == card.userInput else { return }
        let current = actions.snapshot()
        guard canDecideAction, pendingAction?.id == id else { return }
        guard current.commandStamp == card.expectedSnapshot.commandStamp else { refreshActionAvailability(); return }
        // This private accepted intent precedes Published callbacks and the actual side effect.
        executingAction = card
        pendingAction = nil
        let result: ChatActionExecutionResult = cancel
            ? .finished(try! ChatActionReceipt(action: card.action, outcome: .cancelled, detail: "本次操作已取消，未执行。"))
            : actions.execute(card.action, expected: card.expectedSnapshot)
        switch result {
        case .expired(let reason):
            executingAction = nil
            roleErrors[context.id] = reason; partials[context.id] = nil
            refreshCurrent()
        case .finished(let receipt):
            let pair = PendingPair(user: card.userInput, assistant: receipt.assistantText, originalDraft: card.originalDraft, kind: .actionReceipt(receipt.outcome))
            pendingPairs[context.id] = pair
            partials[context.id] = receipt.assistantText
            enqueuePair(pair, id: context.id, feedback: nil)
            executingAction = nil
            refreshCurrent()
        }
    }

    func extractMemories() {
        guard canExtractMemories, let context = character, let archive = archives[context.id] else { return }
        let snapshot: MemoryExtractionSnapshot
        do { snapshot = try .init(conversation: archive, model: connection.model) }
        catch { roleErrors[context.id] = "当前资料无法提炼，请检查完整对话。"; refreshCurrent(); return }
        generation &+= 1
        let current = generation, credentials = credentials, client = memoryClient
        activeRequest = context; activeRequestKind = .memoryExtraction; readingCredential = true; roleErrors[context.id] = nil
        requestTask = Task { [weak self] in
            do {
                guard let key = try await credentials.read() else {
                    guard let self, self.isCurrent(current, context) else { return }
                    self.credentialAvailability = .missing
                    self.failRequest("尚未保存 API 密钥，请到连接页填写。", context: context); return
                }
                guard let self, self.isCurrent(current, context), !Task.isCancelled else { return }
                self.credentialAvailability = .available; self.readingCredential = false; self.refreshCurrent()
                let batch = try await client.extract(snapshot, apiKey: key)
                guard self.isCurrent(current, context), !Task.isCancelled, self.archives[context.id]?.memoryRevision == snapshot.memoryRevision else { return }
                self.requestTask = nil; self.activeRequest = nil; self.activeRequestKind = nil
                self.memoryReview = .init(context: context, snapshot: snapshot, batch: batch)
                self.roleErrors[context.id] = nil; self.refreshCurrent()
            } catch is CancellationError {
                guard let self, self.isCurrent(current, context) else { return }
                self.failRequest("已停止提炼，未保存记忆。", context: context)
            } catch {
                guard let self, self.isCurrent(current, context) else { return }
                self.failRequest((error as? SkinError)?.message ?? "提炼未完成，未保存记忆。可手动重试。", context: context)
            }
        }
        refreshCurrent()
    }
    func setMemoryCandidateText(id: UUID, text: String) {
        guard canEditMemories, !isGenerating, memoryReview?.context == character, memoryReview?.editedTexts[id] != nil else { return }
        memoryReview?.editedTexts[id] = text
    }
    func setMemoryCandidateSelected(id: UUID, selected: Bool) {
        guard canEditMemories, !isGenerating, memoryReview?.context == character, memoryReview?.editedTexts[id] != nil else { return }
        if selected { memoryReview?.selectedIDs.insert(id) } else { memoryReview?.selectedIDs.remove(id) }
    }
    func saveSelectedMemories(reviewID: UUID, for context: ChatCharacter) {
        guard canEditMemories, character == context, let review = memoryReview, review.id == reviewID,
              review.context == context, !review.selectedIDs.isEmpty, let archive = archives[context.id] else { return }
        do {
            let selected = try review.candidates.filter { review.selectedIDs.contains($0.id) }.map {
                try ChatMemory(id: $0.id, text: review.editedTexts[$0.id] ?? $0.text)
            }
            acceptMemoryChange(archive.memories + selected, for: context, expectedRevision: review.snapshot.memoryRevision)
        } catch { roleErrors[context.id] = "候选文字无效，请检查内容和 200 个 UTF-16 单元上限。"; refreshCurrent() }
    }
    func discardMemoryReview() {
        guard canEditMemories, !isGenerating else { return }
        memoryReview = nil; refreshCurrent()
    }
    private func invalidateMemoryReview(for id: String) {
        if memoryReview?.context.id == id { memoryReview = nil }
    }

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
                switch pair.kind {
                case .modelReply: self.roleErrors[id] = "本次对话尚未保存，可重试本地保存或明确丢弃。"
                case .actionReceipt(let outcome):
                    let prefix: String
                    switch outcome {
                    case .applied, .alreadySatisfied: prefix = "操作已执行或目标已满足"
                    case .failed: prefix = "操作未完成"
                    case .cancelled: prefix = "操作已取消，未执行"
                    }
                    self.roleErrors[id] = prefix + "，但聊天回执尚未保存。重试仅保存本地回执；丢弃不会撤销操作。"
                }
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

    func saveMemory(id: UUID, text: String, for context: ChatCharacter, expectedRevision: UInt64) {
        guard canEditMemories, character == context, let prior = archives[context.id],
              let index = prior.memories.firstIndex(where: { $0.id == id }) else { return }
        do {
            var list = prior.memories
            list[index] = try ChatMemory(id: id, text: text)
            acceptMemoryChange(list, for: context, expectedRevision: expectedRevision)
        } catch { roleErrors[context.id] = "记忆文字无效，请检查内容及 200 个 UTF-16 单元的上限。"; refreshCurrent() }
    }
    func deleteMemory(id: UUID, for context: ChatCharacter, expectedRevision: UInt64) {
        guard canEditMemories, character == context, let prior = archives[context.id], prior.memories.contains(where: { $0.id == id }) else { return }
        acceptMemoryChange(prior.memories.filter { $0.id != id }, for: context, expectedRevision: expectedRevision)
    }
    func clearMemories(for context: ChatCharacter, expectedRevision: UInt64) {
        guard canEditMemories, character == context, archives[context.id]?.memories.isEmpty == false else { return }
        acceptMemoryChange([], for: context, expectedRevision: expectedRevision)
    }
    private func acceptMemoryChange(_ memories: [ChatMemory], for context: ChatCharacter, expectedRevision: UInt64) {
        guard canEditMemories, character == context, let prior = archives[context.id] else { return }
        do { _ = try prior.replacingMemories(memories, expectedRevision: expectedRevision) }
        catch { roleErrors[context.id] = "记忆内容重复、超过限制或资料已经变化，请检查后再保存。"; refreshCurrent(); return }
        let change = PendingMemoryChange(characterID: context.id, expectedRevision: expectedRevision, memories: memories)
        pendingMemories[context.id] = change
        enqueueMemoryChange(change)
    }
    private func enqueueMemoryChange(_ change: PendingMemoryChange) {
        let id = change.characterID
        enqueueCharacter(.memories(characterID: id, expectedRevision: change.expectedRevision, memories: change.memories), id: id) { [weak self] result in
            guard let self, self.pendingMemories[id]?.token == change.token else { return }
            switch result {
            case .success:
                self.pendingMemories[id] = nil; self.roleErrors[id] = nil
                self.invalidateMemoryReview(for: id)
                if self.character?.id == id { self.memoryEditRevision &+= 1 }
            case .failure:
                self.roleErrors[id] = "记忆变更尚未保存，原记忆保持不变。可重试本地保存或放弃本次变更。"
            }
        }
    }
    func retryPendingMemorySave() {
        guard canRetryMemorySave, let id = character?.id, let change = pendingMemories[id] else { return }
        enqueueMemoryChange(change)
    }
    func discardPendingMemorySave() {
        guard canRetryMemorySave, let id = character?.id else { return }
        pendingMemories[id] = nil; roleErrors[id] = nil; memoryEditRevision &+= 1; refreshCurrent()
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
                self.invalidateMemoryReview(for: context.id)
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
                self.invalidateMemoryReview(for: context.id)
                if self.character == context { self.memoryEditRevision &+= 1 }
            case .failure: self.roleErrors[context.id] = "记录未能清空，原历史与待存结果保留。"
            }
        }
    }
    func resetCharacterArchive() {
        guard canMutate, executingAction == nil, let context = character, roleWrites[context.id, default: 0] == 0, pendingMemories[context.id] == nil else { return }
        cancelRequest()
        enqueueCharacter(.reset(characterID: context.id, profile: .init(background: context.description)), id: context.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.protectedRoles[context.id] = nil; self.roleErrors[context.id] = nil; self.pendingPairs[context.id] = nil; self.partials[context.id] = nil; self.provisionalInputs[context.id] = nil
                self.invalidateMemoryReview(for: context.id)
                if self.character == context { self.profileEditRevision &+= 1; self.memoryEditRevision &+= 1 }
            case .failure: self.roleErrors[context.id] = "记录未能备份并重置，原资料保持不变。"
            }
        }
    }

    func saveConnection(_ value: ChatConnection) {
        guard canMutate, connectionLoaded else { return }
        if !value.enabled {
            // Disabling is a new intent even while an older preference/key write is pending.
            cancelRequest(); connection.enabled = false
        } else if pendingAction != nil || executingAction != nil || connectionWriting || credentialTask != nil || isGenerating { refreshCurrent(); return }
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
        guard canMutate, pendingAction == nil, executingAction == nil, !isGenerating, !connectionWriting else { return }
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
        guard canMutate, pendingAction == nil, executingAction == nil, !isGenerating, credentialTask == nil else { return }
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
        guard canMutate, pendingAction == nil, executingAction == nil, !isGenerating, credentialTask == nil else { return }
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
    func windowClosed() { cancelRequest(); memoryReview = nil; presented = false; profileEditRevision &+= 1; memoryEditRevision &+= 1; refreshCurrent() }
    func setSleeping(_ sleeping: Bool) {
        guard !disposed, self.sleeping != sleeping else { return }
        self.sleeping = sleeping
        if sleeping { cancelRequest() }
        refreshCurrent()
    }
    func beginTermination() { guard !disposed else { return }; terminating = true; cancelRequest(); memoryReview = nil; memoryEditRevision &+= 1; refreshCurrent() }
    func cancelTermination() { guard !disposed else { return }; terminating = false; refreshCurrent() }
    func waitForPendingWrites() async {
        while true {
            if let credentialTask { await credentialTask.value }
            await writes.waitForPending()
            if credentialTask == nil && !writes.hasPending && executingAction == nil { return }
            await Task.yield()
        }
    }
    func retryAllPendingSaves() async -> Bool {
        guard !disposed else { return false }
        await waitForPendingWrites()
        for (id, pair) in pendingPairs { enqueuePair(pair, id: id, feedback: nil) }
        for change in pendingMemories.values { enqueueMemoryChange(change) }
        if let value = pendingConnection, !connectionWriting { enqueueConnection(value) }
        await waitForPendingWrites()
        return terminationSaveError == nil
    }
    func dispose() {
        guard !disposed else { return }
        cancelRequest(); disposed = true; presented = false
        roleLoadTask?.cancel(); connectionLoadTask?.cancel()
        actions.dispose()
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
        else if activeRequest != nil { state = readingCredential ? .readingCredential : (isExtractingMemories ? .extractingMemories : .streaming) }
        else if pendingAction != nil { state = .awaitingAction }
        else if id.map({ roleWrites[$0, default: 0] > 0 }) == true { state = .saving }
        else if id.flatMap({ pendingPairs[$0] }) != nil { state = .unsaved }
        else if id.flatMap({ pendingMemories[$0] }) != nil { state = .unsavedMemory }
        else { state = error == nil ? .idle : .failed }
    }
}
