import Foundation
import XCTest
import PetCore

final class LocalVoiceEnginePackageTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testPreviewDoesNotExecuteOrCreateDataRoot() throws {
        let parent = try root(), folder = try LocalVoiceEngineFixtures.folder(parent)
        let original = try Data(contentsOf: folder.appendingPathComponent("engine.json"))
        let result = try LocalVoiceEnginePackage.preview(folder: folder)
        XCTAssertEqual(result.manifest.name, "测试引擎")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("engine.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("LocalVoice").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("payload/runtime/bin/preview-ran").path))
        XCTAssertEqual(result.manifestHash.count, 64)
    }
    func testRootAndIntermediateLinksAndExtraFilesAreRejected() throws {
        let parent = try root(), folder = try LocalVoiceEngineFixtures.folder(parent), link = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try LocalVoiceEnginePackage.preview(folder: link))
        let source = folder.appendingPathComponent("payload/source"), moved = parent.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        XCTAssertThrowsError(try LocalVoiceEnginePackage.preview(folder: folder))
        try FileManager.default.removeItem(at: source); try FileManager.default.moveItem(at: moved, to: source)
        try Data("extra".utf8).write(to: folder.appendingPathComponent("payload/unknown.bin"))
        XCTAssertThrowsError(try LocalVoiceEnginePackage.preview(folder: folder))
    }
    func testMissingFixedInterpreterAndMismatchedFileSizesAreRejected() throws {
        let folder = try LocalVoiceEngineFixtures.folder(root())
        let python = folder.appendingPathComponent("payload/runtime/bin/python3.12")
        try Data().write(to: python)
        XCTAssertThrowsError(try LocalVoiceEnginePackage.preview(folder: folder))
        try FileManager.default.removeItem(at: python)
        XCTAssertThrowsError(try LocalVoiceEnginePackage.preview(folder: folder))
    }
    func testOnlyOrdinaryFinderMetadataCanBeIgnored() throws {
        let folder = try LocalVoiceEngineFixtures.folder(root())
        let metadata = folder.appendingPathComponent("payload/.DS_Store")
        try Data("finder".utf8).write(to: metadata)
        XCTAssertNoThrow(try LocalVoiceEnginePackage.preview(folder: folder))
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: folder.appendingPathComponent("engine.json"))
        XCTAssertThrowsError(try LocalVoiceEnginePackage.preview(folder: folder))
    }
}
