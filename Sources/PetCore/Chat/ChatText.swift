import Foundation

public enum ChatText {
    public static func validate(_ text: String, maxUTF16: Int, allowEmpty: Bool) throws {
        let invalidControl = text.unicodeScalars.contains {
            $0.properties.generalCategory == .control && ![9, 10, 13].contains($0.value)
        }
        guard maxUTF16 >= 0, text.utf16.count <= maxUTF16, !invalidControl,
              allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkinError("聊天文字为空、超过长度限制或含有无效控制字符。")
        }
    }

    public static func excerpt(_ text: String, limit: Int = 80) -> String {
        guard limit > 0 else { return "" }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.utf16.count > limit else { return normalized }
        var result = "", used = 0
        for character in normalized {
            let length = String(character).utf16.count
            guard used + length <= limit - 1 else { break }
            result.append(character)
            used += length
        }
        return result + "…"
    }
}
