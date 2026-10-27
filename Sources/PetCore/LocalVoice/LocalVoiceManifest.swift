import Foundation

public struct LocalVoiceError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// StrictJSON preserves the numeric spelling, so booleans and floating point
// lookalikes cannot pass an integer field's validation.
struct LocalVoiceObject {
    let values: [String: JSONValue]
    init(_ value: JSONValue, keys: Set<String>) throws {
        guard case .object(let values) = value, Set(values.keys).isSubset(of: keys) else {
            throw LocalVoiceError("本地语音资料包含未知字段或对象格式错误")
        }
        self.values = values
    }
    func string(_ key: String) throws -> String {
        guard case .string(let value) = values[key] else { throw LocalVoiceError("本地语音字段 \(key) 必须是文字") }
        return value
    }
    func integer(_ key: String) throws -> Int {
        guard case .number(let raw) = values[key], !raw.contains(where: { ".eE".contains($0) }), let value = Int(raw) else {
            throw LocalVoiceError("本地语音字段 \(key) 必须是整数")
        }
        return value
    }
    static func text(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum &&
        !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct LocalVoiceAsset: Codable, Equatable, Sendable {
    public let file: String
    public let bytes: Int
    public let sha256: String
}

public struct LocalVoiceManifest: Codable, Equatable, Sendable {
    public static let profile = "gpt-sovits-v2proplus-cpu1"
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let language: String
    public let engineProfile: String
    public let model: LocalVoiceAsset
    public let reference: LocalVoiceAsset
    public let promptText: String
    public let suggestedCharacterID: String?

    public static func decode(_ data: Data) throws -> Self {
        let root = try LocalVoiceObject(StrictJSON.parse(data, maximumBytes: 16384), keys: ["schemaVersion", "id", "name", "language", "engineProfile", "model", "reference", "promptText", "suggestedCharacterID"])
        let version = try root.integer("schemaVersion"), id = try root.string("id"), name = try root.string("name")
        let language = try root.string("language"), profile = try root.string("engineProfile"), prompt = try root.string("promptText")
        guard version == 1, ManifestDecoder.isValidID(id), LocalVoiceObject.text(name, maximum: 80),
              language == "zh-CN", profile == Self.profile, LocalVoiceObject.text(prompt, maximum: 400) else {
            throw LocalVoiceError("语音包版本、名称、语言或参考文字无效")
        }
        func asset(_ key: String, filename: String, maximum: Int) throws -> LocalVoiceAsset {
            guard let value = root.values[key] else { throw LocalVoiceError("语音包缺少 \(key)") }
            let object = try LocalVoiceObject(value, keys: ["file", "bytes", "sha256"])
            let file = try object.string("file"), bytes = try object.integer("bytes"), sha = try object.string("sha256")
            guard file == filename, (1...maximum).contains(bytes), LocalVoiceObject.digest(sha) else { throw LocalVoiceError("语音包资产 \(key) 无效") }
            return LocalVoiceAsset(file: file, bytes: bytes, sha256: sha)
        }
        var suggested: String?
        if let value = root.values["suggestedCharacterID"], case .null = value {} else if root.values["suggestedCharacterID"] != nil {
            suggested = try root.string("suggestedCharacterID")
            guard ManifestDecoder.isValidID(suggested!) else { throw LocalVoiceError("建议角色 ID 无效") }
        }
        return Self(schemaVersion: version, id: id, name: name, language: language, engineProfile: profile,
                    model: try asset("model", filename: "s2.pth", maximum: 268435456),
                    reference: try asset("reference", filename: "reference.wav", maximum: 1048576),
                    promptText: prompt, suggestedCharacterID: suggested)
    }
}
