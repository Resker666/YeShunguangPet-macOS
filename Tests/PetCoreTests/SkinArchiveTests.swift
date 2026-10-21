import Foundation
import XCTest
import zlib
@testable import PetCore

final class SkinArchiveTests:XCTestCase {
    var directory:URL!
    override func setUpWithError() throws {directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:directory)}
    private func entries(prefix:String="",method:UInt16=0,flags:UInt16=0x800) throws -> [ZIPFixtures.Entry] {
        [.init(prefix+"pet.json",SkinFixtures.minimalManifest,method:method,flags:flags),.init(prefix+"spritesheet.png",try SkinFixtures.directionalPNG(),method:method,flags:flags)]
    }
    private func load(_ entries:[ZIPFixtures.Entry]) throws -> SkinPackage {
        try SkinLoader.readPackage(manifestURL:ZIPFixtures.write(entries,to:directory.appendingPathComponent("角色.ZIP")))
    }
    func testStoredRootArchiveImportsOriginalBytesAfterArchiveRemoval() throws {
        var candidate:SkinPackage?
        XCTAssertNoThrow(candidate=try load(entries()))
        guard let candidate else{return}
        XCTAssertEqual(candidate.skin.manifest.id,"my-pet");XCTAssertEqual(candidate.skin.spriteSheet.width,64)
        try FileManager.default.removeItem(at:directory.appendingPathComponent("角色.ZIP"))
        let copy=try SkinLibrary(directory:directory.appendingPathComponent("Skins")).install(candidate)
        XCTAssertEqual(try Data(contentsOf:copy.skin.directory.appendingPathComponent("pet.json")),SkinFixtures.minimalManifest)
        XCTAssertEqual(try Data(contentsOf:copy.skin.directory.appendingPathComponent("spritesheet.png")),try SkinFixtures.directionalPNG())
    }
    func testDeflateAndDataDescriptorsSupportUnicodeWrapperDirectories() throws {
        for signature in [false,true] {
            var files=try entries(prefix:"下载/我的角色/",method:8,flags:0x808)
            files[0].descriptorSignature=signature;files[1].descriptorSignature=signature
            var candidate:SkinPackage?;XCTAssertNoThrow(candidate=try load(files))
            XCTAssertEqual(candidate?.skin.manifest.name,"我的角色")
            XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("Skins").path))
        }
    }
    func testFinderMetadataAndHarmlessReadmeDoNotBecomeSkinCandidates() throws {
        var files=try entries(prefix:"角色/")
        files += [.init("__MACOSX/pet.json",Data("metadata".utf8)),.init("角色/.DS_Store",Data([1])),.init("README.txt",Data("说明".utf8)),.init("角色/",mode:0o040755)]
        var candidate:SkinPackage?;XCTAssertNoThrow(candidate=try load(files));XCTAssertEqual(candidate?.skin.manifest.id,"my-pet")
    }
    func testMultipleSkinsAreRejectedWithoutChoosingTheFirst() throws {XCTAssertThrowsError(try load(entries()+entries(prefix:"第二套/")))}
    func testMissingManifestOrSameDirectorySpriteIsRejected() throws {
        XCTAssertThrowsError(try load([.init("README.txt",Data([1]))]))
        XCTAssertThrowsError(try load([.init("pet.json",SkinFixtures.minimalManifest),.init("other/spritesheet.png",try SkinFixtures.directionalPNG())]))
    }
    func testInvalidManifestAndPNGUseExistingStrictValidation() throws {
        for json in [Data("{broken".utf8),SkinFixtures.replacing("\"schemaVersion\": 1",with:"\"schemaVersion\": 2")] {XCTAssertThrowsError(try load([.init("pet.json",json),.init("spritesheet.png",try SkinFixtures.directionalPNG())]))}
        XCTAssertThrowsError(try load([.init("pet.json",SkinFixtures.minimalManifest),.init("spritesheet.png",Data("broken".utf8))]))
    }
    func testUnsafePathsAreRejectedEvenForUnusedFiles() throws {
        for path in ["../escaped","/absolute","C:/absolute","a\\b","a//b","a/./b","a/../b","nul\0name"] {
            XCTAssertThrowsError(try load(entries()+[.init(path,Data([1]))]),path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("escaped").path))
    }
    func testLinksAndSpecialFilesAreRejected() throws {
        for mode:UInt32 in [0o120777,0o020666,0o010644] {XCTAssertThrowsError(try load(entries()+[.init("unused",Data("/tmp".utf8),mode:mode)]))}
    }
    func testDuplicateAndConflictingPathsAreRejected() throws {
        for pair in [["pet.json","PET.JSON"],["café.txt","cafe\u{301}.txt"],["file","file/child"]] {
            XCTAssertThrowsError(try load(entries(prefix:"角色/")+pair.map{.init($0,Data([1]))}))
        }
    }
    func testEncryptedUnsupportedAndZIP64EntriesAreRejected() throws {
        XCTAssertThrowsError(try load(entries(flags:0x801)))
        XCTAssertThrowsError(try load(entries(method:12)))
        var files=try entries();files[0].extra=Data([1,0,0,0]);XCTAssertThrowsError(try load(files))
    }
    func testTruncationCRCAndInconsistentLocalHeaderAreRejected() throws {
        for method:UInt16 in [0,8] {
        let good=try ZIPFixtures.archive(entries(method:method))
        for edit in [0,1,2] {
            var bytes=good
            if edit==0{bytes.removeLast()}
            if edit==1{bytes[38] ^= 1} // root pet.json payload
            if edit==2{bytes[8]=99} // local method disagrees with central method
            let url=directory.appendingPathComponent("bad.zip");try bytes.write(to:url)
            XCTAssertThrowsError(try SkinLoader.readPackage(manifestURL:url))
        }
        }
        var files=try entries(method:8);files[0].compressedSuffix=Data([0])
        XCTAssertThrowsError(try load(files))
    }
    func testExpansionBeyondDeclaredSizeIsRejected() throws {
        XCTAssertThrowsError(try load(entries()+[.init("unused",Data(repeating:65,count:131073),method:8,declaredSize:1)]))
    }
    func testEntryCountDepthAndExpandedResourceLimitsAreEnforced() throws {
        XCTAssertThrowsError(try load(entries()+(0..<511).map{.init("unused-\($0)")}))
        XCTAssertThrowsError(try load(entries(prefix:String(repeating:"x/",count:17))))
        XCTAssertThrowsError(try load([.init("pet.json",Data(repeating:32,count:131073)),.init("spritesheet.png",try SkinFixtures.directionalPNG())]))
        XCTAssertThrowsError(try load(entries()+[.init("large",Data(repeating:0,count:64*1024*1024+1),method:8)]))
        let part=Data(repeating:0,count:48*1024*1024)
        XCTAssertThrowsError(try load(entries()+(0..<3).map{.init("part-\($0)",part,method:8)}))
    }
    func testOversizedArchiveAndArchiveSymlinkAreRejectedBeforeReading() throws {
        let large=directory.appendingPathComponent("large.zip");FileManager.default.createFile(atPath:large.path,contents:nil)
        let handle=try FileHandle(forWritingTo:large);try handle.truncate(atOffset:80*1024*1024+1);try handle.close()
        XCTAssertThrowsError(try SkinLoader.readPackage(manifestURL:large))
        let original=try ZIPFixtures.write(entries(),to:directory.appendingPathComponent("valid.zip")),link=directory.appendingPathComponent("linked.zip")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:original);XCTAssertThrowsError(try SkinLoader.readPackage(manifestURL:link))
    }
    func testDirectoryPayloadMustMatchItsEmptyDeclaration() throws {
        for method:UInt16 in [0,8] {
            XCTAssertThrowsError(try load(entries()+[.init("unused/",Data([1]),method:method,mode:0o040755,declaredSize:0)]))
            XCTAssertNoThrow(try load(entries()+[.init("empty/",method:method,mode:0o040755)]))
        }
    }
    func testUnicodePathExtraAndArchiveCommentsPreserveSkinSelection() throws {
        var files=try entries(prefix:"ascii/")
        for index in files.indices {
            let raw=Data(files[index].name.utf8),crc=raw.withUnsafeBytes{UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt($0.count)))}
            let unicode=Data((index==0 ? "皮肤/pet.json":"皮肤/spritesheet.png").utf8),length=unicode.count+5
            files[index].extra=Data([0x75,0x70,UInt8(length),0,1]+(0..<4).map{UInt8(truncatingIfNeeded:crc >> ($0*8))})+unicode
        }
        let zip=directory.appendingPathComponent("unicode.zip")
        try ZIPFixtures.archive(files,comment:Data("comment PK\u{05}\u{06}".utf8)).write(to:zip)
        var candidate:SkinPackage?;XCTAssertNoThrow(candidate=try SkinLoader.readPackage(manifestURL:zip));XCTAssertEqual(candidate?.skin.manifest.id,"my-pet")
    }
    func testExplicitRootDirectoryEntryIsAcceptedAndStillValidated() throws {
        var candidate:SkinPackage?
        XCTAssertNoThrow(candidate=try load([.init("./",mode:0o040755)]+entries(prefix:"./")))
        XCTAssertEqual(candidate?.skin.manifest.id,"my-pet")
        XCTAssertThrowsError(try load([.init("./",Data([1]),mode:0o040755,declaredSize:0)]+entries(prefix:"./")))
        XCTAssertThrowsError(try load([.init("./",mode:0o100644)]+entries(prefix:"./")))
    }
    func testLocalUnicodePathsCannotEscapeOrDisagreeWithCentralNames() throws {
        for path in ["../outside/pet.json","other/pet.json"] {
            var files=try entries();files[0].localExtra=ZIPFixtures.unicodeExtra(name:"pet.json",path:path)
            XCTAssertThrowsError(try load(files),path)
        }
        var valid=try entries();valid[0].localExtra=ZIPFixtures.unicodeExtra(name:"pet.json",path:"pet.json")
        XCTAssertNoThrow(try load(valid))
        var centralOnly=try entries();centralOnly[0].name="ascii.json";centralOnly[0].extra=ZIPFixtures.unicodeExtra(name:"ascii.json",path:"pet.json");centralOnly[0].localExtra=Data()
        XCTAssertNoThrow(try load(centralOnly))
    }
}
