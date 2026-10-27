import Foundation
import XCTest
@testable import PetCore

final class LocalVoiceLibraryTests: XCTestCase {
    func testConfirmedImportUsesSnapshotAfterOriginalFolderReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try LocalVoiceFixtures.folder(root), library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice"))
        let stage = try library.stage(folder: source)
        try FileManager.default.removeItem(at: source)
        let store = LocalVoiceIndexStore(root: library.root)
        let commit = try store.apply(.install(stage)), id = try XCTUnwrap(commit.installedID)
        let voice = try library.resolve(libraryID: id, index: commit.index)
        XCTAssertEqual(try Data(contentsOf: voice.directory.appendingPathComponent("s2.pth")), Data("test".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.privateDirectory.path))
    }
    func testCancelledPreviewNeverRegisters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice"))
        let stage = try library.stage(folder: LocalVoiceFixtures.folder(root))
        try library.discard(stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("index.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.privateDirectory.path))
    }
    func testLinksUnknownFilesAndBadHashesAreRejectedButDSStoreAndTemporaryAliasWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try LocalVoiceFixtures.folder(root), library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice"))
        try Data().write(to: source.appendingPathComponent(".DS_Store"))
        let valid = try library.stage(folder: source); try library.discard(valid)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try library.stage(folder: alias))
        try Data().write(to: source.appendingPathComponent("run.py"))
        XCTAssertThrowsError(try library.stage(folder: source))
        try FileManager.default.removeItem(at: source.appendingPathComponent("run.py"))
        try Data("changed".utf8).write(to: source.appendingPathComponent("s2.pth"))
        XCTAssertThrowsError(try library.stage(folder: source))
        try FileManager.default.removeItem(at: source.appendingPathComponent("s2.pth"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("s2.pth"), withDestinationURL: source.appendingPathComponent("voice.json"))
        XCTAssertThrowsError(try library.stage(folder: source))
    }
    func testBadPackageIsIsolatedAndBoundVoiceCannotBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice")), store = LocalVoiceIndexStore(root: library.root)
        let commit = try store.apply(.install(library.stage(folder: LocalVoiceFixtures.folder(root))))
        let id = try XCTUnwrap(commit.installedID)
        let bound = try store.apply(.bind(characterID: "robin", libraryID: id))
        XCTAssertThrowsError(try store.apply(.remove(id)))
        let voice = try library.resolve(libraryID: id, index: bound.index)
        try Data().write(to: voice.directory.appendingPathComponent("reference.wav"))
        XCTAssertNotNil(library.entries(index: bound.index).first?.issue)
        XCTAssertThrowsError(try library.resolve(libraryID: id, index: bound.index))
    }
    func testGrowingFileIsRejectedWithoutCollectingWeightData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("s2.pth")
        try Data(repeating: 0, count: 131072).write(to: file)
        let fd = try LocalVoiceFile.directory(root)
        defer { close(fd) }
        let empty = try LocalVoiceFile.read("s2.pth", at: fd, maximum: 131072, collect: false).0
        XCTAssertTrue(empty.isEmpty)
        var grown = false
        XCTAssertThrowsError(try LocalVoiceFile.read("s2.pth", at: fd, maximum: 131072, collect: false) { _ in
            if !grown {
                grown = true
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data([1]))
            }
        })
    }
}
