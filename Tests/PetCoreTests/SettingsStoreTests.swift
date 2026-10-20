import XCTest
@testable import PetCore

final class SettingsStoreTests: XCTestCase {
    var directory: URL!, settingsURL: URL!
    let placement=PlacementSnapshot(screenID:"main",origin:CGPoint(x:100,y:200),visibleFrame:CGRect(x:0,y:40,width:1000,height:700))
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); settingsURL=directory.appendingPathComponent("settings.json") }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func testMissingSaveAndReopen() throws {
        let store=SettingsStore(url:settingsURL)
        guard case .missing=store.load() else { return XCTFail("missing") }
        try store.save(placement)
        guard case .loaded(let saved)=SettingsStore(url:settingsURL).load() else { return XCTFail("loaded") }
        XCTAssertEqual(saved,placement)
    }
    func testCorruptSettingsRemainByteIdenticalUntilExplicitReset() throws {
        for bad in [Data("{broken".utf8),Data(#"{"schemaVersion":2}"#.utf8),Data(repeating:32,count:65537)] {
            try bad.write(to:settingsURL)
            let store=SettingsStore(url:settingsURL)
            guard case .protectedFile=store.load() else { return XCTFail("protected") }
            XCTAssertThrowsError(try store.save(placement))
            XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
            try store.backupAndReset(); try store.save(placement)
            let backups=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.contains("backup-")}
            XCTAssertTrue(try backups.contains { try Data(contentsOf:$0)==bad })
        }
    }
    func testAtomicWriteFailureKeepsOriginalAndCanRetry() throws {
        let store=SettingsStore(url:settingsURL); try store.save(placement); let original=try Data(contentsOf:settingsURL)
        let failing=SettingsStore(url:settingsURL,write:{_,_ in throw NSError(domain:"disk",code:1)})
        _=failing.load(); XCTAssertThrowsError(try failing.save(placement)); XCTAssertEqual(try Data(contentsOf:settingsURL),original)
        try store.save(placement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted(),["settings.json"])
    }
    func testBackupFailureLeavesOriginalAndProtectionIntact() throws {
        let bad=Data("{broken".utf8); try bad.write(to:settingsURL)
        let store=SettingsStore(url:settingsURL,backup:{_,_ in throw NSError(domain:"backup",code:1)})
        _=store.load(); XCTAssertThrowsError(try store.backupAndReset())
        XCTAssertThrowsError(try store.save(placement))
        XCTAssertEqual(try Data(contentsOf:settingsURL),bad)
    }
    func testInvalidGeometryAndSixtyFourKiBBoundary() throws {
        let store=SettingsStore(url:settingsURL)
        XCTAssertThrowsError(try store.save(.init(screenID:"x",origin:CGPoint(x:Double.infinity,y:0),visibleFrame:placement.visibleFrame)))
        XCTAssertThrowsError(try store.save(.init(screenID:"",origin:.zero,visibleFrame:placement.visibleFrame)))
        XCTAssertThrowsError(try store.save(.init(screenID:"x",origin:.zero,visibleFrame:.zero)))
        try store.save(placement); let data=try Data(contentsOf:settingsURL)
        try (data+Data(repeating:32,count:65536-data.count)).write(to:settingsURL)
        guard case .loaded=SettingsStore(url:settingsURL).load() else { return XCTFail("64KiB accepted") }
    }
}
