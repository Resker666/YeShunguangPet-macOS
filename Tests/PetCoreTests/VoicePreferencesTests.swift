import Foundation
import XCTest
import PetCore

final class VoicePreferencesTests: XCTestCase {
    func testDefaultsAndAcceptedRateBoundsRoundTrip() throws {
        let defaults = VoicePreferences()
        XCTAssertFalse(defaults.enabled)
        XCTAssertTrue(defaults.automaticReadAloud)
        XCTAssertNil(defaults.voiceIdentifier)
        XCTAssertEqual(defaults.rate, 0.5)
        for rate in [0.35, 0.5, 0.65] {
            let value = VoicePreferences(enabled: true, automaticReadAloud: false, voiceIdentifier: "com.apple.voice.zh-CN", rate: rate)
            try value.validate()
            XCTAssertEqual(try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testInvalidRateAndVoiceIdentifierCannotBeApplied() throws {
        for rate in [0.34, 0.66, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try VoicePreferences(rate: rate).validate())
        }
        for identifier in ["", "bad\nvoice", "bad\0voice", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try VoicePreferences(voiceIdentifier: identifier).validate())
        }
        XCTAssertNoThrow(try VoicePreferences(voiceIdentifier: String(repeating: "a", count: 256)).validate())
    }
}
