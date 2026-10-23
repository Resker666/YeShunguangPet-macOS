import Foundation
import Security
import PetCore

protocol ChatCredentialStoring: Sendable {
    func read() async throws -> String?
    func save(_ secret: String) async throws
    func remove() async throws
}

enum ChatSecret {
    static func normalize(_ secret: String) throws -> String {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw SkinError("API 密钥为空、过长或含有无效字符。")
        }
        return value
    }
}

struct ChatKeychainOperations: Sendable {
    let add: @Sendable (CFDictionary) -> OSStatus
    let copy: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    let update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    let delete: @Sendable (CFDictionary) -> OSStatus
    static let system = ChatKeychainOperations(
        add: { SecItemAdd($0, nil) }, copy: { SecItemCopyMatching($0, $1) },
        update: { SecItemUpdate($0, $1) }, delete: { SecItemDelete($0) }
    )
}

actor KeychainChatCredentialStore: ChatCredentialStoring {
    private let service: String, account: String
    private let operations: ChatKeychainOperations
    init(service: String = "io.github.resker666.yeshunguangpet.macos.deepseek", account: String = "api.deepseek.com", operations: ChatKeychainOperations = .system) {
        self.service = service; self.account = account; self.operations = operations
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled: throw SkinError("已取消钥匙串访问，可稍后重试。")
        case errSecAuthFailed: throw SkinError("钥匙串授权失败，请检查系统授权。")
        case errSecInteractionNotAllowed: throw SkinError("当前无法与钥匙串交互，请解锁后重试。")
        default: throw SkinError("钥匙串操作失败（\(status)）。")
        }
    }
    func read() async throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = operations.copy(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SkinError("钥匙串中的 API 密钥无法读取，请重新保存。")
        }
        return try ChatSecret.normalize(value)
    }
    func save(_ secret: String) async throws {
        let data = Data(try ChatSecret.normalize(secret).utf8)
        var request = query
        request[kSecValueData as String] = data
        let status = operations.add(request as CFDictionary)
        if status == errSecDuplicateItem {
            try check(operations.update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary))
        } else { try check(status) }
    }
    func remove() async throws {
        let status = operations.delete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
