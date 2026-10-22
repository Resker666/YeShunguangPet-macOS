import XCTest
@testable import PetCore

final class FocusStatisticsTests:XCTestCase {
    func testCompletedPlansAccumulateOncePerRecordAndNewDayStartsFresh()throws {
        let first=try FocusDailyStatistics().recording(minutes:25,on:"2026-10-22")
        let next=try first.recording(minutes:15,on:"2026-10-22")
        XCTAssertEqual(next.completedCount,2);XCTAssertEqual(next.plannedMinutes,40)
        XCTAssertEqual(next.forDay("2026-10-23").completedCount,0)
        let tomorrow=try next.recording(minutes:45,on:"2026-10-23")
        XCTAssertEqual(tomorrow.completedCount,1);XCTAssertEqual(tomorrow.plannedMinutes,45)
        XCTAssertEqual(next.plannedMinutes,40)
    }
    func testInvalidDatesCountsAndDurationsAreRejected()throws {
        for day in ["2026-02-29","2026-13-01","2026-1-01","0000-01-01",""] {
            XCTAssertFalse(FocusDailyStatistics(day:day,completedCount:1,plannedMinutes:25).isValid)
            XCTAssertThrowsError(try FocusDailyStatistics().recording(minutes:25,on:day))
        }
        XCTAssertTrue(FocusDailyStatistics(day:"2024-02-29",completedCount:1,plannedMinutes:120).isValid)
        for value in [-1,0,121,Int.max] {XCTAssertThrowsError(try FocusDailyStatistics().recording(minutes:value,on:"2026-10-22"))}
        for value in [FocusDailyStatistics(day:nil,completedCount:1,plannedMinutes:25),.init(day:"2026-10-22",completedCount:-1,plannedMinutes:0),.init(day:"2026-10-22",completedCount:2,plannedMinutes:1),.init(day:"2026-10-22",completedCount:1,plannedMinutes:121),.init(day:"2026-10-22",completedCount:Int.max,plannedMinutes:Int.max)] {XCTAssertFalse(value.isValid)}
    }
    func testDayKeyUsesLocalGregorianDateIncludingTimeZoneChange() {
        let instant=Date(timeIntervalSince1970:1792625400) // 2026-10-21 23:30 UTC
        XCTAssertEqual(FocusDailyStatistics.dayKey(for:instant,timeZone:TimeZone(secondsFromGMT:0)!),"2026-10-21")
        XCTAssertEqual(FocusDailyStatistics.dayKey(for:instant,timeZone:TimeZone(secondsFromGMT:8*3600)!),"2026-10-22")
    }
    func testVersionTwelveMigrationPreservesAllExistingBytesAsValues()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("settings.json"),store=SettingsStore(url:url)
        try store.save(.init(placement:nil,preferences:.init(focusMinutes:45,breakMinutes:10,focusWindow:.init(isVisible:false,alwaysOnTop:false,compact:true),focusCompletionSound:true)))
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]);old["schemaVersion"]=12;old.removeValue(forKey:"focusStatistics")
        try JSONSerialization.data(withJSONObject:old).write(to:url)
        guard case .loaded(let migrated)=store.load() else{return XCTFail("v12 must migrate")}
        XCTAssertEqual(migrated.focusStatistics,.init());try store.save(migrated)
        let encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(encoded["schemaVersion"] as? Int,13)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:encoded["preferences"]!,options:.sortedKeys),try JSONSerialization.data(withJSONObject:old["preferences"]!,options:.sortedKeys))
    }
    func testCurrentStatisticsRoundTripAndInvalidFieldsProtectOriginalBytes()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("settings.json"),store=SettingsStore(url:url)
        let stats=try FocusDailyStatistics().recording(minutes:25,on:"2026-10-22")
        try store.save(.init(placement:nil,focusStatistics:stats))
        guard case .loaded(let loaded)=store.load() else{return XCTFail("must round trip")}
        XCTAssertEqual(loaded.focusStatistics,stats)
        let valid=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        let invalid:[Any?]=[nil,NSNull(),["day":"2026-10-22","completedCount":1],["day":"2026-10-22","completedCount":true,"plannedMinutes":25],["day":"2026-02-30","completedCount":1,"plannedMinutes":25],["completedCount":0,"plannedMinutes":1]]
        for value in invalid {
            var bad=valid;bad["focusStatistics"]=value
            let bytes=try JSONSerialization.data(withJSONObject:bad);try bytes.write(to:url)
            let protected=SettingsStore(url:url)
            guard case .protectedFile=protected.load() else{XCTFail("invalid statistics accepted");continue}
            XCTAssertThrowsError(try protected.save(.init(placement:nil)));XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
    }
}
