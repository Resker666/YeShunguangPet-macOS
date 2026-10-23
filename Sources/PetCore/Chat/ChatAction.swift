import Foundation

public enum ChatAction: Equatable, Sendable {
    case startFocus(minutes: Int), pauseFocus, resumeFocus, setQuiet(enabled: Bool)
}

public enum ChatActionDecoder {
    public static func decode(name: String, arguments: Data) throws -> ChatAction {
        do {
            guard case .object(let fields) = try StrictJSON.parse(arguments, maximumBytes: 4096) else { throw SkinError("invalid") }
            switch name {
            case "start_focus":
                guard Set(fields.keys) == ["minutes"], case .number(let raw) = fields["minutes"],
                      let minutes = Int(raw), (1...120).contains(minutes) else { throw SkinError("invalid") }
                return .startFocus(minutes: minutes)
            case "pause_focus", "resume_focus":
                guard fields.isEmpty else { throw SkinError("invalid") }
                return name == "pause_focus" ? .pauseFocus : .resumeFocus
            case "set_quiet":
                guard Set(fields.keys) == ["enabled"], case .bool(let enabled) = fields["enabled"] else { throw SkinError("invalid") }
                return .setQuiet(enabled: enabled)
            default: throw SkinError("invalid")
            }
        } catch { throw SkinError("操作提议名称或参数无效，未执行任何操作。") }
    }
}

public struct ChatActionReceipt: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case applied, alreadySatisfied, failed, cancelled }
    public let action: ChatAction
    public let outcome: Outcome
    public let detail: String
    public var assistantText: String { "【App操作回执】\n" + detail }
    public init(action: ChatAction, outcome: Outcome, detail: String) throws {
        try ChatText.validate(detail, maxUTF16: 1000, allowEmpty: false)
        self.action = action; self.outcome = outcome; self.detail = detail
    }
}

public enum ChatActionExecutionResult: Equatable, Sendable {
    case expired(String), finished(ChatActionReceipt)
}
