import Foundation

public enum PersonalSpeech {
    public static func parse(_ text:String)throws->[String] {
        let lines=text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
        try validateLines(lines);return lines
    }
    private static func validateLines(_ lines:[String])throws {
        guard lines.count<=8,lines.allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.utf16.count<=80 && !$0.unicodeScalars.contains(where:{$0.properties.generalCategory == .control})}) else {
            throw SkinError("每类台词最多8句，每句1–80个UTF-16单元，不能包含控制字符。")
        }
    }
    public static func validate(_ overrides:[String:SpeechLines])throws {
        guard overrides.count<=16 else{throw SkinError("最多保存16个角色的个人台词，请先清除不再需要的条目。")}
        var total=0
        for (id,lines) in overrides {
            guard ManifestDecoder.isValidID(id) else{throw SkinError("个人台词的角色ID无效。")}
            for event in SpeechEvent.allCases {
                let values=lines.lines(for:event);try validateLines(values)
                total += values.reduce(0){$0+$1.utf16.count}
            }
        }
        guard total<=8192 else{throw SkinError("个人台词总量超过8192个UTF-16单元，请减少内容或清除旧条目。")}
    }
    public static func resolve(id:String,skin:SpeechLines?,overrides:[String:SpeechLines])->SpeechLines {overrides[id] ?? skin ?? .defaults}
}
