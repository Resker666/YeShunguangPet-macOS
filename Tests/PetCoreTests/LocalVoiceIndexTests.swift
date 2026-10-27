import Foundation
import XCTest
import PetCore

final class LocalVoiceIndexTests: XCTestCase {
    private func registration(_ n: Int = 0) -> LocalVoiceRegistration {
        .init(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, packageID: "voice-\(n)", name: "同名音色", contentID: String(format: "%064x", n))
    }
    func testBindingsShareManifestIDAndRejectSeventeenthRole() throws {
        let first = registration()
        var index = try LocalVoiceIndex(packages: [first], bindings: [:])
        for n in 0..<16 { index = try index.binding(characterID: "role-\(n)", to: first.id) }
        XCTAssertEqual(index.binding(for: "role-0"), first.id)
        XCTAssertThrowsError(try index.binding(characterID: "role-16", to: first.id))
        index = try index.binding(characterID: "role-0", to: nil)
        XCTAssertNil(index.binding(for: "role-0"))
        XCTAssertNoThrow(try index.binding(characterID: "role-16", to: first.id))
        XCTAssertThrowsError(try index.binding(characterID: "hutao", to: UUID()))
    }
    func testInvalidReferencesDuplicatesAndCapacityCannotPersist() throws {
        XCTAssertThrowsError(try LocalVoiceIndex(packages: [registration(),registration()], bindings: [:]))
        let duplicatePackage = LocalVoiceRegistration(id: registration(1).id, packageID: registration().packageID, name: "重名", contentID: registration(1).contentID)
        XCTAssertThrowsError(try LocalVoiceIndex(packages: [registration(), duplicatePackage], bindings: [:]))
        let duplicateUUID = LocalVoiceRegistration(id: registration().id, packageID: "different", name: "同一 UUID", contentID: registration(1).contentID)
        XCTAssertThrowsError(try LocalVoiceIndex(packages: [registration(), duplicateUUID], bindings: [:]))
        XCTAssertThrowsError(try LocalVoiceIndex(packages: (0..<17).map { registration($0) }, bindings: [:]))
        XCTAssertNoThrow(try LocalVoiceIndex(packages: (0..<16).map { registration($0) }, bindings: [:]))
        let empty = LocalVoiceIndex()
        XCTAssertEqual(try LocalVoiceIndex.decode(JSONEncoder().encode(empty)), empty)
        XCTAssertThrowsError(try LocalVoiceIndex.decode(Data("{\"schemaVersion\":1,\"schemaVersion\":1,\"packages\":[],\"bindings\":{}}".utf8)))
        XCTAssertThrowsError(try LocalVoiceIndex.decode(Data("{\"schemaVersion\":1.0,\"packages\":[],\"bindings\":{}}".utf8)))
        XCTAssertThrowsError(try LocalVoiceIndex.decode(Data("{\"schemaVersion\":1,\"packages\":[],\"bindings\":{\"hutao\":\"00000000-0000-4000-8000-000000000000\"}}".utf8)))
    }
}
