import Foundation
import XCTest
import Darwin
import PetCore

private final class EngineTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
}

final class LocalVoiceEngineStoreTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func current(_ root: URL) -> URL { root.appendingPathComponent("LocalVoice/Engine/current.json") }
    private func prepared(_ root: URL, hooks: LocalVoiceEngineStore.Hooks = .live) throws -> (LocalVoiceEngineStore, LocalVoiceEngineLease, LocalVoiceEngineCandidate) {
        let store = LocalVoiceEngineStore(dataRoot: root, hooks: hooks), lease = try store.acquire()
        try Data("old descriptor".utf8).write(to: current(root))
        let preview = try LocalVoiceEnginePackage.preview(folder: LocalVoiceEngineFixtures.folder(root))
        let candidate = try store.begin(preview, lease: lease)
        try store.copy(candidate, progress: { _ in }, checkCancelled: { false })
        return (store, lease, candidate)
    }
    func testInstallCopiesAndVerifiesWithoutChangingCurrentBeforeActivation() throws {
        let root = try root(), (store, lease, candidate) = try prepared(root)
        defer { lease.release() }
        XCTAssertEqual(try Data(contentsOf: current(root)), Data("old descriptor".utf8))
        let directory = candidate.configuration.versionRoot
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source/module.py")), LocalVoiceEngineFixtures.contents["source/module.py"])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("runtime/bin/python3.12").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let descriptor = try store.activate(candidate, lease: lease, checkCancelled: { false })
        XCTAssertEqual(descriptor.versionID, candidate.versionID)
        XCTAssertEqual(descriptor.schemaVersion, 2)
        let config = try descriptor.resolve(dataRoot: root)
        XCTAssertEqual(config.pythonURL, directory.appendingPathComponent("runtime/bin/python3.12"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine.json").path))
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("LocalVoice/Engine/Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), Data("old descriptor".utf8))
        XCTAssertThrowsError(try store.discard(versionID: candidate.versionID, lease: lease))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.pythonURL.path))
    }
    func testSourceMutationOrLinkedParentCannotEscape() throws {
        for link in [false, true] {
            let root = try root(), folder = try LocalVoiceEngineFixtures.folder(root), fired = EngineTestFlag()
            let original = Data("old".utf8), outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("untouched".utf8).write(to: outside.appendingPathComponent("secret"))
            var hooks = LocalVoiceEngineStore.Hooks.live
            hooks.inspectChunk = { path, _ in
                if path == "source/module.py", !fired.value {
                    fired.value = true
                    if link {
                        let source = folder.appendingPathComponent("payload/source")
                        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("moved"))
                        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
                    } else {
                        let file = try FileHandle(forWritingTo: folder.appendingPathComponent("payload/source/module.py"))
                        try file.seekToEnd(); try file.write(contentsOf: Data("growth".utf8)); try file.close()
                    }
                }
            }
            let store = LocalVoiceEngineStore(dataRoot: root, hooks: hooks), lease = try store.acquire(); defer { lease.release() }
            try original.write(to: current(root))
            let candidate = try store.begin(LocalVoiceEnginePackage.preview(folder: folder), lease: lease)
            XCTAssertThrowsError(try store.copy(candidate, progress: { _ in }, checkCancelled: { false }))
            XCTAssertTrue(fired.value); XCTAssertEqual(try Data(contentsOf: current(root)), original)
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret")), Data("untouched".utf8))
            try store.discard(versionID: candidate.versionID, lease: lease)
        }
    }
    func testCommitCancellationHasOneLinearizationPoint() throws {
        for before in [true, false] {
            let root = try root(), cancel = EngineTestFlag()
            var hooks = LocalVoiceEngineStore.Hooks.live
            if before { hooks.beforeCommit = { cancel.value = true } }
            else { hooks.afterCommit = { cancel.value = true } }
            let (store, lease, candidate) = try prepared(root, hooks: hooks); defer { lease.release() }
            if before {
                XCTAssertThrowsError(try store.activate(candidate, lease: lease, checkCancelled: { cancel.value }))
                XCTAssertEqual(try Data(contentsOf: current(root)), Data("old descriptor".utf8))
                try store.discard(versionID: candidate.versionID, lease: lease)
            } else {
                let result = try store.activate(candidate, lease: lease, checkCancelled: { cancel.value })
                XCTAssertTrue(cancel.value); XCTAssertEqual(result.versionID, candidate.versionID)
                XCTAssertEqual(try LocalVoiceEngineDescriptor.load(dataRoot: root).versionID, candidate.versionID)
                XCTAssertThrowsError(try store.discard(versionID: candidate.versionID, lease: lease))
            }
        }
    }
    func testRetryRejectsChangedDescriptorAndKeepsOldVersion() throws {
        let root = try root(), (store, lease, candidate) = try prepared(root)
        lease.release()
        let changed = Data("another process changed current".utf8); try changed.write(to: current(root))
        let next = try store.acquire(); defer { next.release() }
        XCTAssertThrowsError(try store.activate(candidate, lease: next, checkCancelled: { false }))
        XCTAssertEqual(try Data(contentsOf: current(root)), changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.configuration.versionRoot.path))
    }
    func testWriteAndBackupFailuresKeepCandidateForLocalRetryWithoutSource() throws {
        for backup in [true, false] {
            let root = try root(), fail = EngineTestFlag(); fail.value = true
            var hooks = LocalVoiceEngineStore.Hooks.live
            if backup { hooks.beforeBackup = { if fail.value { throw LocalVoiceError("backup failure") } } }
            else { hooks.beforeCommit = { if fail.value { throw LocalVoiceError("write failure") } } }
            let (store, lease, candidate) = try prepared(root, hooks: hooks); defer { lease.release() }
            XCTAssertThrowsError(try store.activate(candidate, lease: lease, checkCancelled: { false }))
            XCTAssertEqual(try Data(contentsOf: current(root)), Data("old descriptor".utf8))
            try FileManager.default.removeItem(at: candidate.preview.folder)
            fail.value = false
            XCTAssertEqual(try store.activate(candidate, lease: lease, checkCancelled: { false }).versionID, candidate.versionID)
        }
    }
    func testInsufficientSpaceAndLinkedTargetParentNeverCreateVersion() throws {
        let root = try root(), preview = try LocalVoiceEnginePackage.preview(folder: LocalVoiceEngineFixtures.folder(root))
        var hooks = LocalVoiceEngineStore.Hooks.live; hooks.availableBytes = { _ in 0 }
        let store = LocalVoiceEngineStore(dataRoot: root, hooks: hooks), lease = try store.acquire(); defer { lease.release() }
        XCTAssertThrowsError(try store.begin(preview, lease: lease))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("LocalVoice/Engine/Versions").path), [])
        lease.release()
        let outside = root.appendingPathComponent("unrelated"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let versions = root.appendingPathComponent("LocalVoice/Engine/Versions")
        try FileManager.default.removeItem(at: versions); try FileManager.default.createSymbolicLink(at: versions, withDestinationURL: outside)
        XCTAssertThrowsError(try store.acquire())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testCleanupFailureCanRetryAndDoesNotFollowOwnedLinks() throws {
        let root = try root(), fail = EngineTestFlag(); fail.value = true
        var hooks = LocalVoiceEngineStore.Hooks.live; hooks.beforeRemove = { _ in if fail.value { throw LocalVoiceError("remove failure") } }
        let (store, lease, candidate) = try prepared(root, hooks: hooks); defer { lease.release() }
        XCTAssertThrowsError(try store.discard(versionID: candidate.versionID, lease: lease))
        let outside = root.appendingPathComponent("outside"); try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: candidate.configuration.versionRoot.appendingPathComponent("unregistered-link"), withDestinationURL: outside)
        fail.value = false; try store.discard(versionID: candidate.versionID, lease: lease)
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.configuration.versionRoot.path))
    }
    func testSchema2RejectsLinkedRuntimeAndKeepsLegacyReadable() throws {
        let root = try root(), (store, lease, candidate) = try prepared(root); defer { lease.release() }
        let descriptor = try store.activate(candidate, lease: lease, checkCancelled: { false })
        let bin = candidate.configuration.versionRoot.appendingPathComponent("runtime/bin"), other = root.appendingPathComponent("other-bin")
        try FileManager.default.moveItem(at: bin, to: other); try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: other)
        XCTAssertThrowsError(try descriptor.resolve(dataRoot: root))
    }
    func testSharedProcessLockPreventsVersionCreation() throws {
        let root = try root(), engine = root.appendingPathComponent("LocalVoice/Engine")
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", "import fcntl,sys;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_SH);print('x',flush=True);sys.stdin.buffer.read(1)", engine.appendingPathComponent("use.lock").path]
        child.standardOutput = output; child.standardInput = input
        try child.run(); defer { try? input.fileHandleForWriting.write(contentsOf: Data([1])); try? input.fileHandleForWriting.close(); child.waitUntilExit() }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("x".utf8))
        XCTAssertThrowsError(try LocalVoiceEngineStore(dataRoot: root).acquire())
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.appendingPathComponent("Versions").path))
    }
}
