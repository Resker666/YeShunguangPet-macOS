import Foundation
import XCTest
@testable import PetCore

final class ReleaseInfoTests:XCTestCase {
    private func payload(tag:String="v0.1.12",assetArch:String="arm64",notes:String="Hello",change:([String:Any])->[String:Any]={$0}) throws -> Data {
        let stem="YeShunguangPet-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)-macOS-\(assetArch).dmg"
        return try JSONSerialization.data(withJSONObject:change(["tag_name":tag,"draft":false,"prerelease":false,"html_url":"https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/\(tag)","body":notes,"assets":[["name":stem,"browser_download_url":"https://github.com/Resker666/YeShunguangPet-macOS/releases/download/\(tag)/\(stem)"]]]))
    }
    private func info(tag:String) throws -> ReleaseInfo {try .parse(payload(tag:tag),architecture:.arm64)}
    func testNumericVersionOrderAndDevelopmentAhead() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion(tag:"v0.1.10")),try XCTUnwrap(ReleaseVersion(tag:"0.1.9")))
        XCTAssertEqual(try info(tag:"v0.1.9").comparison(to:XCTUnwrap(ReleaseVersion(tag:"0.1.12"))),.ahead)
        XCTAssertEqual(try info(tag:"v0.1.12").comparison(to:XCTUnwrap(ReleaseVersion(tag:"0.1.12"))),.current)
        XCTAssertEqual(try info(tag:"v0.2.0").comparison(to:XCTUnwrap(ReleaseVersion(tag:"0.1.12"))),.newer)
        for tag in ["v0.1.12-beta","4294967296.1.0","0.1","0.1.2.3","-1.1.0","０.1.0","1e0.1.0"," 0.1.0"] {XCTAssertNil(ReleaseVersion(tag:tag),tag)}
        XCTAssertEqual(ReleaseVersion(tag:"0.0.0")?.description,"0.0.0")
        XCTAssertNotNil(ReleaseVersion(tag:"4294967295.0.0"))
    }
    func testStableOfficialLinksAndMissingArchitecture() throws {
        let result=try ReleaseInfo.parse(payload(notes:String(repeating:"字",count:8001)),architecture:.arm64)
        XCTAssertEqual(result.notes.count,8000)
        XCTAssertEqual(result.downloadURL?.lastPathComponent,"YeShunguangPet-0.1.12-macOS-arm64.dmg")
        let missing=try ReleaseInfo.parse(payload(assetArch:"x86_64"),architecture:.arm64)
        XCTAssertNil(missing.downloadURL);XCTAssertEqual(missing.pageURL.path,"/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.12")
    }
    func testUntrustedAndNonPublicReleasesAreRejected() throws {
        for field in ["draft","prerelease"] {
            XCTAssertThrowsError(try ReleaseInfo.parse(payload{var p=$0;p[field]=true;return p},architecture:.arm64))
        }
        for url in ["http://github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.12","https://example.org/","https://user@github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.12","https://github.com:443/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.12","https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.12?x=1","https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/v0.1.12#x","https://github.com/other/repo/releases/tag/v0.1.12"] {
            XCTAssertThrowsError(try ReleaseInfo.parse(payload{var p=$0;p["html_url"]=url;return p},architecture:.arm64))
        }
        for data in [Data("{bad".utf8),Data("{}".utf8)] {XCTAssertThrowsError(try ReleaseInfo.parse(data,architecture:.arm64))}
    }
    func testBadAssetLinksCannotBeOpened() throws {
        for url in ["https://evil.invalid/a.dmg","https://github.com/Resker666/YeShunguangPet-macOS/releases/download/v0.1.11/YeShunguangPet-0.1.12-macOS-arm64.dmg","https://u@github.com/Resker666/YeShunguangPet-macOS/releases/download/v0.1.12/YeShunguangPet-0.1.12-macOS-arm64.dmg"] {
            let data=try payload{var p=$0;p["assets"]=[["name":"YeShunguangPet-0.1.12-macOS-arm64.dmg","browser_download_url":url]];return p}
            XCTAssertThrowsError(try ReleaseInfo.parse(data,architecture:.arm64))
        }
    }
}
