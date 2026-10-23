import Foundation
import PetCore

actor ControlledChatPersistence: ChatPersisting {
    let worker: ChatArchiveWorker
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
    func loadCharacter(id: String, defaultProfile: ChatProfile) async -> ChatLoadResult<ChatConversation> {
        await worker.loadCharacter(id: id, defaultProfile: defaultProfile)
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
