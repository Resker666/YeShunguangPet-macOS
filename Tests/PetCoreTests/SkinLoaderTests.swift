import Foundation
import XCTest
import CoreGraphics
@testable import PetCore

final class SkinLoaderTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func testLegacySkinDimensionsAndFirstCrop() throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"pet",withExtension:"json",subdirectory:"Pets/YeShunguang"))
        let skin=try SkinLoader.load(manifestURL:url)
        XCTAssertEqual(skin.manifest.id,"ye-shunguang"); XCTAssertEqual(skin.spriteSheet.width,1536)
        let frame=try SpriteAtlas(skin:skin).frame(at:.init(row:0,column:0))
        XCTAssertEqual(frame.width,192); XCTAssertEqual(frame.height,208)
    }
    func testRejectsLinksEmptyCorruptMismatchedAndOversizedImages() throws {
        let manifest=try SkinFixtures.writePackage(in:directory)
        let image=directory.appendingPathComponent("spritesheet.png"), original=try Data(contentsOf:image)
        for bad in [Data(),Data("bad".utf8),Data(original.prefix(33)),Data(repeating:0,count:64*1024*1024+1)] {
            try bad.write(to:image); XCTAssertThrowsError(try SkinLoader.load(manifestURL:manifest))
        }
        try original.write(to:image)
        try SkinFixtures.manifest(["rows":2]).write(to:manifest)
        XCTAssertThrowsError(try SkinLoader.load(manifestURL:manifest))
        try SkinFixtures.minimalManifest.write(to:manifest)
        let other=directory.appendingPathComponent("source.png"); try FileManager.default.moveItem(at:image,to:other)
        try FileManager.default.createSymbolicLink(at:image,withDestinationURL:other)
        XCTAssertThrowsError(try SkinLoader.load(manifestURL:manifest))
        let alias=directory.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:directory)
        XCTAssertThrowsError(try SkinLoader.load(manifestURL:alias.appendingPathComponent("pet.json")))
        let actual=directory.appendingPathComponent("original.json"); try FileManager.default.moveItem(at:manifest,to:actual)
        try FileManager.default.createSymbolicLink(at:manifest,withDestinationURL:actual)
        XCTAssertThrowsError(try SkinLoader.load(manifestURL:manifest))
    }
    func testBoundedReaderRejectsGrowthAndNonRegularFiles() throws {
        var chunks=[Data(repeating:1,count:8),Data(repeating:2,count:8)]
        XCTAssertThrowsError(try SkinLoader.readLimited(maximumBytes:10) { _ in chunks.isEmpty ? Data() : chunks.removeFirst() })
        XCTAssertThrowsError(try SkinLoader.readFile(at:directory,maximumBytes:100))
    }
}
