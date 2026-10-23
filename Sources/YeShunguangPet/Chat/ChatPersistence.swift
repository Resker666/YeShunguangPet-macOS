import Foundation
import PetCore

enum ChatWriteOperation: Sendable {
    case profile(characterID: String, profile: ChatProfile)
    case append(characterID: String, user: String, assistant: String)
    case clear(characterID: String)
    case reset(characterID: String, profile: ChatProfile)
    case memories(characterID: String, expectedRevision: UInt64, memories: [ChatMemory])
    case connection(ChatConnection)
    case resetConnection
}

enum ChatStoredValue: Sendable { case character(ChatConversation), connection(ChatConnection) }
struct ChatWriteTicket: Equatable, Sendable { let sequence: UInt64 }

protocol ChatPersisting: Sendable {
    func loadCharacter(id: String, defaultProfile: ChatProfile) async -> ChatLoadResult<ChatConversation>
    func loadConnection() async -> ChatLoadResult<ChatConnection>
    func apply(_ operation: ChatWriteOperation) async throws -> ChatStoredValue
}

actor ChatArchiveWorker: ChatPersisting {
    private let store: ChatStore, connectionStore: ChatConnectionStore
    private var characters = [String: ChatConversation](), protections = [String: String]()
    private var connection: ChatConnection?, connectionProtection: String?
    private var connectionLoaded = false

    init(settingsURL: URL) {
        let root = settingsURL.deletingLastPathComponent().appendingPathComponent("AI", isDirectory: true)
        store = ChatStore(directory: root.appendingPathComponent("characters", isDirectory: true))
        connectionStore = ChatConnectionStore(url: root.appendingPathComponent("connection.json"))
    }

    private func load(id: String, defaultProfile: ChatProfile) -> ChatLoadResult<ChatConversation> {
        if let message = protections[id] { return .protectedFile(message) }
        if let value = characters[id] { return .loaded(value) }
        switch store.load(characterID: id) {
        case .missing:
            do {
                characters[id] = try ChatConversation(characterID: id, profile: defaultProfile)
                return .missing
            } catch { return .protectedFile("角色聊天初始资料无效。") }
        case .loaded(let value):
            characters[id] = value; return .loaded(value)
        case .protectedFile(let message):
            protections[id] = message; return .protectedFile(message)
        }
    }
    func loadCharacter(id: String, defaultProfile: ChatProfile) async -> ChatLoadResult<ChatConversation> {
        load(id: id, defaultProfile: defaultProfile)
    }
    func loadConnection() async -> ChatLoadResult<ChatConnection> {
        if connectionLoaded {
            if let message = connectionProtection { return .protectedFile(message) }
            return .loaded(connection ?? .init())
        }
        connectionLoaded = true
        let result = connectionStore.load()
        switch result {
        case .missing: connection = .init()
        case .loaded(let value): connection = value
        case .protectedFile(let message): connectionProtection = message
        }
        return result
    }

    private func current(_ id: String) throws -> ChatConversation {
        _ = load(id: id, defaultProfile: .init())
        guard protections[id] == nil, let value = characters[id] else { throw SkinError("原聊天档案受保护，请先备份并重置。") }
        return value
    }
    private func save(_ value: ChatConversation) throws -> ChatStoredValue {
        try store.save(value)
        characters[value.characterID] = value
        return .character(value)
    }

    func apply(_ operation: ChatWriteOperation) async throws -> ChatStoredValue {
        switch operation {
        case .profile(let id, let profile):
            let prior = try current(id)
            return try save(prior.replacingProfile(profile))
        case .append(let id, let user, let assistant):
            return try save(current(id).appending(user: user, assistant: assistant))
        case .clear(let id):
            return try save(current(id).clearingHistory())
        case .memories(let id, let revision, let memories):
            return try save(current(id).replacingMemories(memories, expectedRevision: revision))
        case .reset(let id, let profile):
            let value = try store.backupAndReset(characterID: id, profile: profile)
            characters[id] = value; protections[id] = nil
            return .character(value)
        case .connection(let value):
            try connectionStore.save(value)
            connection = value; connectionLoaded = true; connectionProtection = nil
            return .connection(value)
        case .resetConnection:
            let value = try connectionStore.backupAndReset()
            connection = value; connectionLoaded = true; connectionProtection = nil
            return .connection(value)
        }
    }
}

@MainActor final class ChatWriteQueue {
    private struct Entry {
        let ticket: ChatWriteTicket
        let operation: ChatWriteOperation
        let completion: @MainActor (ChatWriteTicket, Result<ChatStoredValue, Error>) -> Void
    }
    private let persistence: any ChatPersisting
    private var entries = [Entry](), waiters = [CheckedContinuation<Void, Never>]()
    private var runner: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var active = false
    var hasPending: Bool { active || !entries.isEmpty }
    init(persistence: any ChatPersisting) { self.persistence = persistence }

    @discardableResult func enqueue(_ operation: ChatWriteOperation, completion: @escaping @MainActor (ChatWriteTicket, Result<ChatStoredValue, Error>) -> Void) -> ChatWriteTicket {
        sequence &+= 1
        let ticket = ChatWriteTicket(sequence: sequence)
        entries.append(Entry(ticket: ticket, operation: operation, completion: completion))
        if runner == nil { runner = Task { await self.drain() } }
        return ticket
    }

    private func drain() async {
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            active = true
            let result: Result<ChatStoredValue, Error>
            do { result = .success(try await persistence.apply(entry.operation)) }
            catch { result = .failure(error) }
            active = false
            entry.completion(entry.ticket, result)
        }
        runner = nil
        let ready = waiters; waiters.removeAll()
        ready.forEach { $0.resume() }
    }

    func waitForPending() async {
        guard hasPending else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
