import Foundation
import XCTest
import PetCore

final class LocalVoicePCMTests: XCTestCase {
    private func reference(_ data: Data) throws -> LocalVoicePCMInfo {
        try LocalVoicePCM.validate(data, maximumBytes: 1048576, minimumSeconds: 3, maximumSeconds: 10)
    }
    func testReferenceAcceptsThreeAndTenSecondsOnly() throws {
        XCTAssertEqual(try reference(LocalVoiceFixtures.pcm()).frames, 96000)
        XCTAssertEqual(try reference(LocalVoiceFixtures.pcm(seconds: 10)).frames, 320000)
        for seconds in [0.0, 2.999, 10.001] { XCTAssertThrowsError(try reference(LocalVoiceFixtures.pcm(seconds: seconds))) }
        XCTAssertNoThrow(try LocalVoicePCM.validate(LocalVoiceFixtures.pcm(seconds: 0.1), maximumBytes: 33554432, minimumSeconds: 0, maximumSeconds: 240))
    }
    func testWrongFormatsTruncationAndChunkOverflowAreRejected() throws {
        for data in [LocalVoiceFixtures.pcm(rate: 16000), LocalVoiceFixtures.pcm(channels: 2), LocalVoiceFixtures.pcm(bits: 8), Data(), LocalVoiceFixtures.pcm().dropLast()] {
            XCTAssertThrowsError(try reference(Data(data)))
        }
        var overflow = LocalVoiceFixtures.pcm(); overflow.replaceSubrange(40..<44, with: [255,255,255,255])
        XCTAssertThrowsError(try reference(overflow))
        var trailing = LocalVoiceFixtures.pcm(); trailing.append(0)
        XCTAssertThrowsError(try reference(trailing))
    }
    func testUnknownOddChunkRequiresPaddingAndDuplicateDataIsRejected() throws {
        let original = LocalVoiceFixtures.pcm()
        var padded = original
        padded.insert(contentsOf: Array("JUNK".utf8) + [1,0,0,0,42,0], at: 12)
        var size = UInt32(padded.count - 8).littleEndian
        withUnsafeBytes(of: &size) { padded.replaceSubrange(4..<8, with: $0) }
        XCTAssertNoThrow(try reference(padded))
        var duplicate = original
        duplicate.append(contentsOf: Array("data".utf8) + [2,0,0,0,0,0])
        size = UInt32(duplicate.count - 8).littleEndian
        withUnsafeBytes(of: &size) { duplicate.replaceSubrange(4..<8, with: $0) }
        XCTAssertThrowsError(try reference(duplicate))
    }
}
