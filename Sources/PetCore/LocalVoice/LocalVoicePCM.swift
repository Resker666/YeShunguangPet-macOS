import Foundation

public struct LocalVoicePCMInfo: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let frames: Int
    public var duration: Double { Double(frames) / Double(sampleRate) }
}

public enum LocalVoicePCM {
    public static func validate(_ data: Data, maximumBytes: Int, minimumSeconds: Double, maximumSeconds: Double) throws -> LocalVoicePCMInfo {
        func fail() -> LocalVoiceError { LocalVoiceError("音频必须是完整、有界的 32 kHz 单声道 PCM16 WAV") }
        guard data.count >= 44, data.count <= maximumBytes, minimumSeconds.isFinite, maximumSeconds.isFinite,
              minimumSeconds >= 0, maximumSeconds >= minimumSeconds else { throw fail() }
        // Byte reads avoid alignment assumptions and never allocate from a chunk's declared size.
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func tag(_ at: Int, _ text: String) -> Bool { data[at..<at + 4].elementsEqual(text.utf8) }
        guard tag(0, "RIFF"), tag(8, "WAVE"), u32(4) == data.count - 8 else { throw fail() }
        var at = 12, format = false, samples: Int?
        while at < data.count {
            guard data.count - at >= 8 else { throw fail() }
            let count = u32(at + 4), start = at + 8
            guard count <= data.count - start else { throw fail() }
            if tag(at, "fmt ") {
                guard !format, count == 16, u16(start) == 1, u16(start + 2) == 1, u32(start + 4) == 32000,
                      u32(start + 8) == 64000, u16(start + 12) == 2, u16(start + 14) == 16 else { throw fail() }
                format = true
            } else if tag(at, "data") {
                guard samples == nil, count > 0, count % 2 == 0 else { throw fail() }
                samples = count / 2
            }
            let padded = count + count % 2
            guard padded <= data.count - start else { throw fail() }
            at = start + padded
        }
        guard format, let frames = samples else { throw fail() }
        let duration = Double(frames) / 32000
        guard duration >= minimumSeconds, duration <= maximumSeconds else { throw fail() }
        return LocalVoicePCMInfo(sampleRate: 32000, channels: 1, frames: frames)
    }
}
