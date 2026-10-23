import Foundation

public struct ChatMemory: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) throws {
        self.id = id
        self.text = try Self.normalizedText(text)
    }

    public static func normalizedText(_ text: String) throws -> String {
        let result = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        try ChatText.validate(result, maxUTF16: 200, allowEmpty: false)
        return result
    }

    public static func validate(_ memories: [ChatMemory]) throws {
        guard memories.count <= 20 else { throw SkinError("每个角色最多保存 20 条记忆，请先整理已有条目。") }
        var ids = Set<UUID>(), texts = Set<String>()
        for memory in memories {
            let normalized = try normalizedText(memory.text)
            guard normalized.utf8.elementsEqual(memory.text.utf8), ids.insert(memory.id).inserted,
                  texts.insert(normalized).inserted else {
                throw SkinError("记忆条目重复或文字格式无效。")
            }
        }
    }
}
