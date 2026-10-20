import XCTest

final class LaunchOptionsTests: XCTestCase {
    func testRejectsMissingRepeatedRelativeAndUnknownArguments() {
        for args in [["--skin"],["--skin","pet.json"],["--other"],["--skin","/a/pet.json","--skin","/b/pet.json"]] { XCTAssertThrowsError(try LaunchOptions.parse(args)) }
    }
    func testAcceptsAbsoluteSkinPath() throws {
        XCTAssertEqual(try LaunchOptions.parse(["--skin","/a/pet.json"]).skinURL?.path,"/a/pet.json")
        XCTAssertNil(try LaunchOptions.parse([]).skinURL)
    }
}
