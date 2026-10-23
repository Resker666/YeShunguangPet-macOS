import Foundation
import CryptoKit

public enum ChatLoadResult<Value: Sendable>: Sendable {
    case missing
    case loaded(Value)
    case protectedFile(String)
}

public final class ChatStore {
    private struct Archive: Codable { let schemaVersion: Int; let conversation: ChatConversation }
    public let directory: URL
    private let write: (Data, URL) throws -> Void
    private let backup: (URL, URL) throws -> Void
    private var checked = Set<String>(), blocked = Set<String>()

    public init(directory: URL, write: ((Data, URL) throws -> Void)? = nil, backup: ((URL, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.write = write ?? { try ChatAtomicFile.write($0, to: $1) }
        self.backup = backup ?? { try ChatAtomicFile.backup($0, to: $1) }
    }

    private func url(for id: String) throws -> URL {
        guard ManifestDecoder.isValidID(id) else { throw SkinError("聊天角色标识无效。") }
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    private func checkDirectories(create: Bool) throws {
        try ChatAtomicFile.directory(directory.deletingLastPathComponent(), create: create)
        try ChatAtomicFile.directory(directory, create: create)
    }

    public func load(characterID: String) -> ChatLoadResult<ChatConversation> {
        checked.insert(characterID)
        do {
            let file = try url(for: characterID)
            try checkDirectories(create: false)
            guard let data = try ChatAtomicFile.read(file, maximumBytes: 2097152) else {
                blocked.remove(characterID); return .missing
            }
            try StrictJSON.validate(data, maximumBytes: 2097152)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == 1, archive.conversation.characterID == characterID else { throw SkinError("聊天档案版本或角色不匹配。") }
            try archive.conversation.validate()
            blocked.remove(characterID)
            return .loaded(archive.conversation)
        } catch {
            blocked.insert(characterID)
            return .protectedFile("聊天记录无法读取，原文件保持不变。请备份并重置该角色记录。")
        }
    }

    public func save(_ value: ChatConversation) throws {
        try value.validate()
        if !checked.contains(value.characterID) { _ = load(characterID: value.characterID) }
        guard !blocked.contains(value.characterID) else { throw SkinError("原聊天记录受保护，请先备份并重置。") }
        do { try persist(value) }
        catch { throw SkinError("聊天记录未能保存，原文件保持不变。可重试本地保存。") }
    }

    private func persist(_ value: ChatConversation) throws {
        let data = try JSONEncoder().encode(Archive(schemaVersion: 1, conversation: value))
        guard data.count <= 2097152 else { throw SkinError("聊天记录超过允许大小。") }
        try checkDirectories(create: true)
        try write(data, url(for: value.characterID))
    }

    public func backupAndReset(characterID: String, profile: ChatProfile) throws -> ChatConversation {
        let fresh = try ChatConversation(characterID: characterID, profile: profile)
        let file = try url(for: characterID)
        _ = load(characterID: characterID)
        do {
            try checkDirectories(create: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SkinError("聊天记录类型无效。") }
                try backup(file, file.appendingPathExtension("backup-" + UUID().uuidString))
            }
            try persist(fresh)
            checked.insert(characterID); blocked.remove(characterID)
            return fresh
        } catch { throw SkinError("聊天记录未能备份并重置，原资料仍受保护。") }
    }
}
