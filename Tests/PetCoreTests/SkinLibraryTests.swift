import XCTest
@testable import PetCore

final class SkinLibraryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func testImportUsesValidatedSnapshotAndSurvivesRemovalOfOriginal() throws {
        let source=directory.appendingPathComponent("source")
        let manifest=try SkinFixtures.writePackage(in:source)
        let json=try Data(contentsOf:manifest), png=try Data(contentsOf:source.appendingPathComponent("spritesheet.png"))
        let candidate=try SkinLoader.readPackage(manifestURL:manifest)
        // The original may change after preview; import the bytes actually previewed.
        try Data("{broken".utf8).write(to:manifest)
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        let imported=try library.install(candidate)
        XCTAssertNotNil(UUID(uuidString:imported.id))
        XCTAssertEqual(try Data(contentsOf:imported.skin.directory.appendingPathComponent("pet.json")),json)
        XCTAssertEqual(try Data(contentsOf:imported.skin.directory.appendingPathComponent("spritesheet.png")),png)
        XCTAssertEqual(try Data(contentsOf:manifest),Data("{broken".utf8))
        try FileManager.default.removeItem(at:source)
        let restored=try SkinLibrary(directory:library.directory).load(id:imported.id)
        XCTAssertEqual(restored.manifest.name,"我的角色")
        XCTAssertEqual(restored.spriteSheet.width,64)
        XCTAssertEqual(try SpriteAtlas(skin:restored).frame(at:.init(row:0,column:0)).height,32)
    }
    func testPreviewDoesNotCreateLibraryOrWriteSource() throws {
        let source=directory.appendingPathComponent("source"), root=directory.appendingPathComponent("Skins")
        let manifest=try SkinFixtures.writePackage(in:source)
        let original=try Data(contentsOf:manifest)
        let package=try SkinLoader.readPackage(manifestURL:manifest)
        XCTAssertEqual(package.skin.manifest.id,"my-pet")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        XCTAssertEqual(try Data(contentsOf:manifest),original)
    }
    func testFailedCopyCleansStagingAndKeepsPriorImport() throws {
        let candidate=try SkinLoader.readPackage(manifestURL:SkinFixtures.writePackage(in:directory.appendingPathComponent("source")))
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        let first=try library.install(candidate)
        var writes=0
        XCTAssertThrowsError(try library.install(candidate,writeFile:{ data,url in
            writes += 1
            if writes==2 { throw NSError(domain:"disk",code:1) }
            try data.write(to:url,options:.withoutOverwriting)
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:library.directory.path),[first.id])
        XCTAssertEqual(try library.load(id:first.id).manifest.id,"my-pet")
    }
    func testImportsWithSameManifestIDNeverOverwriteEarlierAssets() throws {
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("source"))
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        let first=try library.install(SkinLoader.readPackage(manifestURL:manifest))
        try SkinFixtures.manifest(["name":"第二个角色"]).write(to:manifest)
        let second=try library.install(SkinLoader.readPackage(manifestURL:manifest))
        XCTAssertNotEqual(first.id,second.id)
        XCTAssertEqual(try library.load(id:first.id).manifest.name,"我的角色")
        XCTAssertEqual(try library.load(id:second.id).manifest.name,"第二个角色")
    }
    func testRejectsPathIDsAndLinkedManagedDirectories() throws {
        let candidate=try SkinLoader.readPackage(manifestURL:SkinFixtures.writePackage(in:directory.appendingPathComponent("source")))
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        for value in ["../source","/tmp/skin","https://example.test/pet.json","my-pet",""] {
            XCTAssertThrowsError(try library.load(id:value))
        }
        let first=try library.install(candidate)
        let link=directory.appendingPathComponent("LinkedSkins")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:library.directory)
        XCTAssertThrowsError(try SkinLibrary(directory:link).install(candidate))
        XCTAssertThrowsError(try SkinLibrary(directory:link).load(id:first.id))
        let managed=library.directory.appendingPathComponent(first.id)
        try FileManager.default.removeItem(at:managed)
        try FileManager.default.createSymbolicLink(at:managed,withDestinationURL:directory.appendingPathComponent("source"))
        XCTAssertThrowsError(try library.load(id:first.id))
    }
    func testOnlyDeclaredResourcesAreCopiedAndCustomPNGNameIsRetained() throws {
        let source=directory.appendingPathComponent("source")
        let manifest=try SkinFixtures.writePackage(in:source)
        try FileManager.default.moveItem(at:source.appendingPathComponent("spritesheet.png"),to:source.appendingPathComponent("custom.png"))
        try SkinFixtures.manifest(["spriteSheet":"custom.png"]).write(to:manifest)
        try Data("private".utf8).write(to:source.appendingPathComponent("unrelated.txt"))
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        let imported=try library.install(SkinLoader.readPackage(manifestURL:manifest))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:imported.skin.directory.path).sorted(),["custom.png","pet.json"])
    }
    func testLibraryDiscoversOldCopiesAndKeepsDamagedEntriesSeparate() throws {
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("source"))
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        let first=try library.install(SkinLoader.readPackage(manifestURL:manifest))
        try SkinFixtures.manifest(["name":"第二个角色"]).write(to:manifest)
        let second=try library.install(SkinLoader.readPackage(manifestURL:manifest))
        try FileManager.default.removeItem(at:directory.appendingPathComponent("source"))
        let damagedID=UUID().uuidString, damaged=library.directory.appendingPathComponent(damagedID)
        try FileManager.default.createDirectory(at:damaged,withIntermediateDirectories:false)
        try Data("broken".utf8).write(to:damaged.appendingPathComponent("pet.json"))
        try FileManager.default.createDirectory(at:library.directory.appendingPathComponent(".import-\(UUID().uuidString)"),withIntermediateDirectories:false)
        try FileManager.default.createSymbolicLink(at:library.directory.appendingPathComponent(UUID().uuidString),withDestinationURL:first.skin.directory)
        let entries=try library.entries()
        XCTAssertEqual(Set(entries.map(\.id)),Set([first.id,second.id,damagedID]))
        let old=try XCTUnwrap(entries.first{$0.id==first.id})
        XCTAssertEqual(old.name,"我的角色")
        XCTAssertEqual(old.thumbnail?.width,32); XCTAssertEqual(old.thumbnail?.height,32)
        XCTAssertNil(old.loadError)
        XCTAssertEqual(entries.first{$0.id==second.id}?.name,"第二个角色")
        XCTAssertNotNil(entries.first{$0.id==damagedID}?.loadError)
        XCTAssertNil(entries.first{$0.id==damagedID}?.thumbnail)
    }
    func testMissingLibraryIsEmptyAndLinkedRootIsRejected() throws {
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.directory.path))
        try FileManager.default.createSymbolicLink(at:library.directory,withDestinationURL:directory)
        XCTAssertThrowsError(try library.entries())
    }
    func testRemoveOnlyDeletesRequestedCopyAndRejectsLinksAndPathIDs() throws {
        let manifest=try SkinFixtures.writePackage(in:directory.appendingPathComponent("source"))
        let library=SkinLibrary(directory:directory.appendingPathComponent("Skins"))
        let package=try SkinLoader.readPackage(manifestURL:manifest)
        let first=try library.install(package), second=try library.install(package)
        try library.remove(id:first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:first.skin.directory.path))
        XCTAssertEqual(try library.load(id:second.id).manifest.id,"my-pet")
        XCTAssertTrue(FileManager.default.fileExists(atPath:manifest.path))
        let linkID=UUID().uuidString
        try FileManager.default.createSymbolicLink(at:library.directory.appendingPathComponent(linkID),withDestinationURL:manifest.deletingLastPathComponent())
        for id in ["../source",linkID] { XCTAssertThrowsError(try library.remove(id:id)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:manifest.path))
        let linked=directory.appendingPathComponent("LinkedSkins")
        try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:library.directory)
        XCTAssertThrowsError(try SkinLibrary(directory:linked).remove(id:second.id))
    }
}
