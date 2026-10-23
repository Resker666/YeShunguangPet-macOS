import Foundation
import XCTest
import PetCore

actor ControlledChatPersistence: ChatPersisting {
    let worker: ChatArchiveWorker
    private var heldLoads = Set<String>()
    private var loadReleases = [String: CheckedContinuation<Void, Never>]()
    private var loadWaiters = [String: CheckedContinuation<Void, Never>]()
    private var arrivedLoads = Set<String>()
    private var holdWrite = false
    private var release: CheckedContinuation<Void, Never>?
    private var failures = Set<String>()
    private var waiters = [(Int, CheckedContinuation<Void, Never>)]()
    private(set) var operations = [String]()
    init(settingsURL: URL) { worker = ChatArchiveWorker(settingsURL: settingsURL) }
    func holdNextWrite() { holdWrite = true }
    func failNext(_ name: String) { failures.insert(name) }
    func waitForOperations(_ count: Int) async {
        if operations.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
    func releaseWrite() { release?.resume(); release = nil }
    func holdNextLoad(_ id: String) { heldLoads.insert(id) }
    func waitForLoad(_ id: String) async { if !arrivedLoads.contains(id) { await withCheckedContinuation { loadWaiters[id] = $0 } } }
    func releaseLoad(_ id: String) { loadReleases.removeValue(forKey: id)?.resume() }
    func releaseAllLoads() { let values=Array(loadReleases.values);loadReleases=[:];values.forEach{$0.resume()} }
    func loadCharacter(id: String, defaultProfile: ChatProfile) async -> ChatLoadResult<ChatConversation> {
        let result = await worker.loadCharacter(id: id, defaultProfile: defaultProfile)
        arrivedLoads.insert(id);loadWaiters.removeValue(forKey: id)?.resume()
        if heldLoads.remove(id) != nil { await withCheckedContinuation { loadReleases[id] = $0 } }
        return result
    }
    func loadConnection() async -> ChatLoadResult<ChatConnection> { await worker.loadConnection() }
    func apply(_ operation: ChatWriteOperation) async throws -> ChatStoredValue {
        let name: String
        switch operation {
        case .profile(let id, _): name = "profile:" + id
        case .append(let id, _, _): name = "append:" + id
        case .clear(let id): name = "clear:" + id
        case .reset(let id, _): name = "reset:" + id
        case .connection: name = "connection"
        case .resetConnection: name = "resetConnection"
        }
        operations.append(name)
        let ready = waiters.filter { $0.0 <= operations.count }
        waiters.removeAll { $0.0 <= operations.count }; ready.forEach { $0.1.resume() }
        if holdWrite { holdWrite = false; await withCheckedContinuation { release = $0 } }
        if failures.remove(name) != nil { throw SkinError("注入的聊天写入失败。") }
        return try await worker.apply(operation)
    }
}

@MainActor final class ChatTestFlag { var value = false }


actor ControlledChatCredentials: ChatCredentialStoring {
    private var key: String? = "TEST-ONLY"
    private var held = false, failSave = false
    private var release: CheckedContinuation<Void, Never>?
    private var waiters = [(Int, CheckedContinuation<Void, Never>)]()
    private var readFailure: String?
    private(set) var reads = 0
    func holdNextRead() { held = true }
    func failNextSave() { failSave = true }
    func setReadFailure(_ message: String?) { readFailure = message }
    func setKey(_ value: String?) { key = value }
    func waitForReads(_ count: Int) async { if reads < count { await withCheckedContinuation { waiters.append((count, $0)) } } }
    func releaseRead() { release?.resume(); release = nil }
    func read() async throws -> String? {
        reads += 1
        let ready = waiters.filter { $0.0 <= reads }; waiters.removeAll { $0.0 <= reads }; ready.forEach { $0.1.resume() }
        if held { held = false; await withCheckedContinuation { release = $0 } }
        if let readFailure { throw SkinError(readFailure) }
        return key
    }
    func save(_ secret: String) async throws {
        if failSave { failSave = false; throw SkinError("注入的密钥保存失败。") }
        key = secret
    }
    func remove() async throws { key = nil }
}

final class ControlledChatClient: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [ChatPromptSnapshot]()
    private var continuations = [Int: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation]()
    var count: Int { lock.withLock { requests.count } }
    func stream(_ snapshot: ChatPromptSnapshot, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { let id = requests.count; requests.append(snapshot); continuations[id] = continuation }
        }
    }
    func emit(_ id: Int, _ text: String) { lock.withLock { continuations[id] }?.yield(.delta(text)) }
    func complete(_ id: Int, answer: String) {
        let continuation = lock.withLock { continuations.removeValue(forKey: id) }
        continuation?.yield(.delta(answer)); continuation?.yield(.completed); continuation?.finish()
    }
    func finishAll() {
        let remaining = lock.withLock { let values = Array(continuations.values); continuations = [:]; return values }
        remaining.forEach { $0.finish(throwing: CancellationError()) }
    }
}

@MainActor func chatEventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if clock.now >= deadline { XCTFail("Chat condition timed out", file: file, line: line); throw NSError(domain: "ChatConditionTimeout", code: 1) }
        await Task.yield()
    }
}

@MainActor final class ChatControllerFixture {
    let root: URL
    let persistence: ControlledChatPersistence
    let credentials = ControlledChatCredentials()
    let client = ControlledChatClient()
    let controller: ChatController
    let feedback: ChatFeedback
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-controller-" + UUID().uuidString)
        try ChatConnectionStore(url: root.appendingPathComponent("AI/connection.json")).save(.init(enabled: true))
        persistence = ControlledChatPersistence(settingsURL: root.appendingPathComponent("settings.json"))
        let feedback = ChatFeedback(); self.feedback = feedback
        controller = ChatController(persistence: persistence, credentials: credentials, client: client, canDispatch: { true }, onFeedback: { feedback.lines.append($0) })
    }
    func open(_ id: String = "robin", revision: UInt64 = 0) async throws {
        controller.activate(.init(id: id, name: id, description: "角色介绍", skinRevision: revision))
        try await chatEventually { self.controller.character?.id == id && self.controller.conversation != nil && self.controller.state != .loading && self.controller.connectionLoaded }
    }
    func send(_ input: String, answer: String, index: Int) async throws {
        controller.setDraft(input); controller.send()
        try await chatEventually { self.client.count == index + 1 }
        client.complete(index, answer: answer)
        try await chatEventually { self.controller.state == .idle && !self.controller.hasPendingWrites }
    }
    func close() async {
        controller.beginTermination()
        await credentials.releaseRead(); await persistence.releaseWrite(); await persistence.releaseAllLoads()
        client.finishAll()
        await controller.waitForPendingWrites()
        controller.dispose()
        try? FileManager.default.removeItem(at: root)
    }
}
@MainActor final class ChatFeedback { var lines = [String]() }
