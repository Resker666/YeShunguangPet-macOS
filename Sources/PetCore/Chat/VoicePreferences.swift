import Foundation

public struct VoicePreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var automaticReadAloud: Bool
    public var voiceIdentifier: String?
    public var rate: Double

    public init(enabled: Bool = false, automaticReadAloud: Bool = true, voiceIdentifier: String? = nil, rate: Double = 0.5) {
        self.enabled = enabled; self.automaticReadAloud = automaticReadAloud
        self.voiceIdentifier = voiceIdentifier; self.rate = rate
    }

    public func validate() throws {
        guard rate.isFinite, (0.35...0.65).contains(rate) else { throw SkinError("语速应在 0.35–0.65 之间。") }
        if let voiceIdentifier {
            guard !voiceIdentifier.isEmpty, voiceIdentifier.utf16.count <= 256,
                  !voiceIdentifier.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw SkinError("系统音色标识无效。")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case enabled, automaticReadAloud, voiceIdentifier, rate }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(automaticReadAloud, forKey: .automaticReadAloud)
        try values.encode(voiceIdentifier, forKey: .voiceIdentifier)
        try values.encode(rate, forKey: .rate)
    }
}
