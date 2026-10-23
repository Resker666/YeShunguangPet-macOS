import Foundation

public final class ChatConnectionStore {
    private struct Archive: Codable { let schemaVersion: Int; let connection: ChatConnection }
    public let url: URL
    private let write: (Data, URL) throws -> Void
    private let backup: (URL, URL) throws -> Void
    private var checked = false, blocked = false

    public init(url: URL, write: ((Data, URL) throws -> Void)? = nil, backup: ((URL, URL) throws -> Void)? = nil) {
        self.url = url
        self.write = write ?? { try ChatAtomicFile.write($0, to: $1) }
        self.backup = backup ?? { try ChatAtomicFile.backup($0, to: $1) }
    }

    public func load() -> ChatLoadResult<ChatConnection> {
        checked = true
        do {
            try ChatAtomicFile.directory(url.deletingLastPathComponent(), create: false)
            guard let data = try ChatAtomicFile.read(url, maximumBytes: 8192) else { blocked = false; return .missing }
            try StrictJSON.validate(data, maximumBytes: 8192)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == 1 else { throw SkinError("AI 连接配置版本无效。") }
            blocked = false
            return .loaded(archive.connection)
        } catch {
            blocked = true
            return .protectedFile("AI 连接配置无法读取，原文件保持不变。请备份并重置连接。")
        }
    }

    public func save(_ value: ChatConnection) throws {
        if !checked { _ = load() }
        guard !blocked else { throw SkinError("原 AI 连接配置受保护，请先备份并重置。") }
        do { try persist(value) }
        catch { throw SkinError("AI 连接偏好未保存，原偏好保持不变。") }
    }

    private func persist(_ value: ChatConnection) throws {
        let data = try JSONEncoder().encode(Archive(schemaVersion: 1, connection: value))
        guard data.count <= 8192 else { throw SkinError("AI 连接配置超过允许大小。") }
        try ChatAtomicFile.directory(url.deletingLastPathComponent(), create: true)
        try write(data, url)
    }

    public func backupAndReset() throws -> ChatConnection {
        _ = load()
        do {
            try ChatAtomicFile.directory(url.deletingLastPathComponent(), create: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SkinError("AI 连接配置类型无效。") }
                try backup(url, url.appendingPathExtension("backup-" + UUID().uuidString))
            }
            let value = ChatConnection()
            try persist(value)
            blocked = false; checked = true
            return value
        } catch { throw SkinError("AI 连接配置未能备份并重置，原资料仍受保护。") }
    }
}
