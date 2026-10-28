import XCTest
import Foundation
import PetCore

@MainActor final class LocalVoiceEngineWorkerTests: XCTestCase {
    func testWorkerKeepsLeaseUntilReleaseAndCurrentIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let worker = LocalVoiceEngineWorker(dataRoot:root)
        let missing = await worker.current(); XCTAssertEqual(missing.status,.unconfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        let folder = try LocalVoiceEngineFixtures.folder(root), preview = try await worker.preview(folder:folder), candidate = try await worker.begin(preview)
        try await worker.copy(candidate,progress:{ _ in })
        XCTAssertThrowsError(try LocalVoiceEngineStore(dataRoot:root).acquire())
        let descriptor = try await worker.activate(candidate); XCTAssertEqual(descriptor.schemaVersion,2)
        await worker.releaseLease(); let lease = try LocalVoiceEngineStore(dataRoot:root).acquire(); lease.release()
        let snapshot = await worker.current(); XCTAssertEqual(snapshot.descriptor?.versionID,candidate.versionID)
        XCTAssertEqual(snapshot.configuration?.versionRoot,candidate.configuration.versionRoot)
    }
}
