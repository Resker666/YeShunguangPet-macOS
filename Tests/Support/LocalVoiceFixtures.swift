import Foundation
import CryptoKit

enum LocalVoiceFixtures {
    static func folder(_ parent: URL, name: String = UUID().uuidString, id: String = "hutao-pilot-e1") throws -> URL {
        let directory = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest { $0["id"] = id }.write(to: directory.appendingPathComponent("voice.json"))
        try Data("test".utf8).write(to: directory.appendingPathComponent("s2.pth"))
        try pcm().write(to: directory.appendingPathComponent("reference.wav"))
        return directory
    }
    static let testSHA = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    static func pcm(seconds: Double = 3, rate: UInt32 = 32000, channels: UInt16 = 1, bits: UInt16 = 16) -> Data {
        let frames = Int(seconds * Double(rate)), size = frames * Int(channels) * Int(bits / 8)
        var data = Data("RIFF".utf8)
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + size)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1)
        u16(channels); u32(rate); u32(rate * UInt32(channels) * UInt32(bits / 8))
        u16(channels * (bits / 8)); u16(bits); data.append(Data("data".utf8)); u32(UInt32(size))
        data.append(Data(repeating: 1, count: size)); return data
    }
    static func manifest(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let audio = pcm()
        var object: [String: Any] = [
            "schemaVersion": 1, "id": "hutao-pilot-e1", "name": "胡桃 · 试用", "language": "zh-CN",
            "engineProfile": "gpt-sovits-v2proplus-cpu1", "promptText": "你好，今天过得怎么样？",
            "model": ["file": "s2.pth", "bytes": 4, "sha256": testSHA],
            "reference": ["file": "reference.wav", "bytes": audio.count, "sha256": SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()],
            "suggestedCharacterID": "hutao"
        ]
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
