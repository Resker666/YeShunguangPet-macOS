import Foundation

public struct LocalVoiceRegistration: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let packageID: String
    public let name: String
    public let contentID: String
    public init(id: UUID, packageID: String, name: String, contentID: String) {
        self.id = id; self.packageID = packageID; self.name = name; self.contentID = contentID
    }
}

public struct LocalVoiceIndex: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packages: [LocalVoiceRegistration]
    public let bindings: [String: UUID]
    public init() { schemaVersion = 1; packages = []; bindings = [:] }
    public init(packages: [LocalVoiceRegistration], bindings: [String: UUID]) throws {
        guard packages.count <= 16, bindings.count <= 16,
              Set(packages.map(\.id)).count == packages.count, Set(packages.map(\.packageID)).count == packages.count,
              packages.allSatisfy({ ManifestDecoder.isValidID($0.packageID) && LocalVoiceObject.text($0.name, maximum: 80) && LocalVoiceObject.digest($0.contentID) }),
              bindings.allSatisfy({ role, id in ManifestDecoder.isValidID(role) && packages.contains(where: { $0.id == id }) }) else {
            throw LocalVoiceError("语音库重复、超出 16 项或引用了不存在的音色")
        }
        schemaVersion = 1; self.packages = packages; self.bindings = bindings
    }
    public func binding(for characterID: String) -> UUID? { bindings[characterID] }
    public func binding(characterID: String, to id: UUID?) throws -> Self {
        guard ManifestDecoder.isValidID(characterID) else { throw LocalVoiceError("角色 ID 无效") }
        var next = bindings; next[characterID] = id
        return try Self(packages: packages, bindings: next)
    }
    public static func decode(_ data: Data) throws -> Self {
        let root = try LocalVoiceObject(StrictJSON.parse(data, maximumBytes: 65536), keys: ["schemaVersion", "packages", "bindings"])
        guard try root.integer("schemaVersion") == 1, case .array(let list) = root.values["packages"], case .object(let bindingValues) = root.values["bindings"], list.count <= 16, bindingValues.count <= 16 else { throw LocalVoiceError("语音库索引格式无效") }
        let packages = try list.map { item -> LocalVoiceRegistration in
            let entry = try LocalVoiceObject(item, keys: ["id", "packageID", "name", "contentID"])
            guard let id = UUID(uuidString: try entry.string("id")) else { throw LocalVoiceError("语音库 UUID 无效") }
            return try LocalVoiceRegistration(id: id, packageID: entry.string("packageID"), name: entry.string("name"), contentID: entry.string("contentID"))
        }
        var bindings: [String: UUID] = [:]
        for (role, value) in bindingValues {
            guard case .string(let raw) = value, let id = UUID(uuidString: raw) else { throw LocalVoiceError("音色绑定 UUID 无效") }
            bindings[role] = id
        }
        return try Self(packages: packages, bindings: bindings)
    }
}
