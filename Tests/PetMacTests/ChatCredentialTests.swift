import Foundation
import Security
import XCTest

private final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var statuses: [OSStatus] = []
    private(set) var queries = [[String: String]]()
    private(set) var actions = [String]()
    func fail(_ status: OSStatus) { lock.withLock { statuses = [status] } }
    private func record(_ action: String, _ query: CFDictionary) -> OSStatus? {
        let fields = query as NSDictionary
        queries.append([
            "service": fields[kSecAttrService] as? String ?? "",
            "account": fields[kSecAttrAccount] as? String ?? "",
            "class": fields[kSecClass] as? String ?? "",
            "dataProtection": fields[kSecUseDataProtectionKeychain] == nil ? "absent" : "present",
            "group": fields[kSecAttrAccessGroup] == nil ? "absent" : "present"
        ])
        actions.append(action)
        return statuses.isEmpty ? nil : statuses.removeFirst()
    }
    var operations: ChatKeychainOperations {
        ChatKeychainOperations(
            add: { [self] query in lock.withLock {
                if let failure = record("add", query) { return failure }
                if value != nil { return errSecDuplicateItem }
                value = (query as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }},
            copy: { [self] query, output in lock.withLock {
                if let failure = record("copy", query) { return failure }
                guard let value else { return errSecItemNotFound }
                output.pointee = value as CFData
                return errSecSuccess
            }},
            update: { [self] query, attributes in lock.withLock {
                if let failure = record("update", query) { return failure }
                guard value != nil else { return errSecItemNotFound }
                value = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }},
            delete: { [self] query in lock.withLock {
                if let failure = record("delete", query) { return failure }
                guard value != nil else { return errSecItemNotFound }
                value = nil; return errSecSuccess
            }}
        )
    }
}

final class ChatCredentialTests: XCTestCase {
    func testCredentialFailureMappingAndNoFileStorage() async throws {
        let memory = MemoryKeychain()
        let store = KeychainChatCredentialStore(service: "test-service", account: "test-account", operations: memory.operations)
        let missing = try await store.read()
        XCTAssertNil(missing)
        try await store.save(" \nTEST-FIRST\n ")
        let first = try await store.read()
        XCTAssertEqual(first, "TEST-FIRST")
        try await store.save("TEST-SECOND")
        let second = try await store.read()
        XCTAssertEqual(second, "TEST-SECOND")
        XCTAssertEqual(Array(memory.actions.suffix(3)), ["add", "update", "copy"])
        for query in memory.queries {
            XCTAssertEqual(query["service"], "test-service")
            XCTAssertEqual(query["account"], "test-account")
            XCTAssertEqual(query["dataProtection"], "absent")
            XCTAssertEqual(query["group"], "absent")
        }
        for bad in [" ", "TEST\nINJECTION", String(repeating: "x", count: 4097)] {
            do { try await store.save(bad); XCTFail("invalid credential accepted") } catch {}
        }
        let unchanged = try await store.read()
        XCTAssertEqual(unchanged, "TEST-SECOND")
        var descriptions = Set<String>()
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            memory.fail(status)
            do { _ = try await store.read(); XCTFail("keychain failure accepted") }
            catch { descriptions.insert(error.localizedDescription); XCTAssertFalse(error.localizedDescription.contains("TEST-SECOND")) }
        }
        XCTAssertEqual(descriptions.count, 3)
        try await store.remove()
        try await store.remove()
        let removed = try await store.read()
        XCTAssertNil(removed)
    }
}
