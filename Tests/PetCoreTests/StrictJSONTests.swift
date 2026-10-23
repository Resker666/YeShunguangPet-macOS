import Foundation
import XCTest
@testable import PetCore
final class StrictJSONTests: XCTestCase {
    func testEncodingDepthAndSizeBoundaries() throws {
        _ = try ManifestDecoder.decode(Data([0xef,0xbb,0xbf]) + SkinFixtures.minimalManifest)
        XCTAssertThrowsError(try StrictJSON.validate(Data([0xff])))
        try StrictJSON.validate(Data((String(repeating:"[",count:64)+"0"+String(repeating:"]",count:64)).utf8))
        XCTAssertThrowsError(try StrictJSON.validate(Data((String(repeating:"[",count:65)+"0"+String(repeating:"]",count:65)).utf8)))
        let padding = Data(repeating:32,count:131072-SkinFixtures.minimalManifest.count)
        _ = try ManifestDecoder.decode(SkinFixtures.minimalManifest+padding)
        XCTAssertThrowsError(try ManifestDecoder.decode(SkinFixtures.minimalManifest+padding+Data([32])))
        // Chat may opt into a larger byte budget; the shared grammar and depth stay strict.
        try StrictJSON.validate(SkinFixtures.minimalManifest+padding+Data([32]), maximumBytes: 2097152)
        XCTAssertThrowsError(try StrictJSON.validate(Data((String(repeating:"[",count:65)+"0"+String(repeating:"]",count:65)).utf8), maximumBytes: 2097152))
        XCTAssertThrowsError(try StrictJSON.validate(Data("{\"x\":1,\"X\":2}".utf8), maximumBytes: 2097152))
    }
}
