import Foundation

public struct VoiceInsertion: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
    public init(text: String, selection: NSRange) { self.text = text; self.selection = selection }
}

public enum VoiceText {
    public static func inserting(_ transcript: String, into draft: String, replacing selection: NSRange) throws -> VoiceInsertion {
        try ChatText.validate(transcript, maxUTF16: 2000, allowEmpty: false)
        let value = draft as NSString, length = value.length
        var start = selection.location == NSNotFound ? length : min(max(0, selection.location), length)
        var end = start + min(selection.length, length - start)
        if start < length { start = value.rangeOfComposedCharacterSequence(at: start).location }
        if selection.length == 0 { end = start }
        else if end > start, end < length {
            let character = value.rangeOfComposedCharacterSequence(at: end)
            if character.location < end { end = NSMaxRange(character) }
        }
        let result = value.replacingCharacters(in: NSRange(location: start, length: end - start), with: transcript)
        try ChatText.validate(result, maxUTF16: 2000, allowEmpty: false)
        return VoiceInsertion(text: result, selection: NSRange(location: start + transcript.utf16.count, length: 0))
    }

    public static func automaticExcerpt(_ text: String) -> String {
        guard text.utf16.count > 600 else { return text }
        var prefix = "", used = 0
        for character in text {
            let length = String(character).utf16.count
            guard used + length <= 600 else { break }
            prefix.append(character); used += length
        }
        if let sentenceEnd = prefix.lastIndex(where: { "。！？!?\n.".contains($0) }) {
            let end = prefix.index(after: sentenceEnd)
            if prefix[..<end].utf16.count >= 440 { return String(prefix[..<end]) }
        }
        return prefix
    }
}
