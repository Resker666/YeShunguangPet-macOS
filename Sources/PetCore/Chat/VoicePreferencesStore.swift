import Foundation
import CoreFoundation

public final class VoicePreferencesStore {
    private struct Archive: Codable { let schemaVersion: Int; let preferences: VoicePreferences }
    public let url: URL
    private let write: (Data, URL) throws -> Void
    private let backup: (URL, URL) throws -> Void
    private var checked = false, blocked = false

    public init(url: URL, write: ((Data, URL) throws -> Void)? = nil, backup: ((URL, URL) throws -> Void)? = nil) {
        self.url = url
        self.write = write ?? { try ChatAtomicFile.write($0, to: $1) }
        self.backup = backup ?? { try ChatAtomicFile.backup($0, to: $1) }
    }

    public func load() -> ChatLoadResult<VoicePreferences> {
        checked = true
        do {
            try ChatAtomicFile.directory(url.deletingLastPathComponent(), create: false)
            guard let data = try ChatAtomicFile.read(url, maximumBytes: 8192) else { blocked = false; return .missing }
            try StrictJSON.validate(data, maximumBytes: 8192)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == ["schemaVersion", "preferences"],
                  let version = root["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let values = root["preferences"] as? [String: Any],
                  Set(values.keys) == ["enabled", "automaticReadAloud", "voiceIdentifier", "rate"] else { throw SkinError("语音配置结构无效。") }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == 1 else { throw SkinError("语音配置版本无效。") }
            try archive.preferences.validate()
            blocked = false
            return .loaded(archive.preferences)
        } catch {
            blocked = true
            return .protectedFile("语音偏好无法读取，原文件保持不变；其他文字聊天仍可使用。请备份并重置语音偏好。")
        }
    }

    public func save(_ value: VoicePreferences) throws {
        if !checked { _ = load() }
        guard !blocked else { throw SkinError("原语音偏好受保护，请先备份并重置。") }
        do { try persist(value) }
        catch { throw SkinError("语音偏好未保存，原文件保持不变。") }
    }

    private func persist(_ value: VoicePreferences) throws {
        try value.validate()
        let data = try JSONEncoder().encode(Archive(schemaVersion: 1, preferences: value))
        guard data.count <= 8192 else { throw SkinError("语音偏好超过允许大小。") }
        try ChatAtomicFile.directory(url.deletingLastPathComponent(), create: true)
        try write(data, url)
    }

    public func backupAndReset() throws -> VoicePreferences {
        _ = load()
        do {
            try ChatAtomicFile.directory(url.deletingLastPathComponent(), create: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SkinError("语音偏好类型无效。") }
                try backup(url, url.appendingPathExtension("backup-" + UUID().uuidString))
            }
            let value = VoicePreferences()
            try persist(value)
            checked = true; blocked = false
            return value
        } catch { throw SkinError("语音偏好未能备份并重置，原文件保持不变。") }
    }
}
