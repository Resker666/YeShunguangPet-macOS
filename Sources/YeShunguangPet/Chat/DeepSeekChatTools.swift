import Foundation

struct DeepSeekToolDefinition: Encodable, Sendable {
    struct Property: Encodable, Sendable {
        let type: String
        let description: String
        let minimum: Int?
        let maximum: Int?
    }
    struct Parameters: Encodable, Sendable {
        let type = "object"
        let properties: [String: Property]
        let required: [String]
        let additionalProperties = false
    }
    struct Function: Encodable, Sendable {
        let name, description: String
        let parameters: Parameters
    }
    let type = "function"
    let function: Function
}

enum DeepSeekChatTools {
    static let definitions: [DeepSeekToolDefinition] = [
        .init(function: .init(name: "start_focus", description: "提议开始明确时长的专注；仅focus/ready。用户确认后先保存为常用时长。", parameters: .init(properties: ["minutes": .init(type: "integer", description: "用户明确给出的分钟数", minimum: 1, maximum: 120)], required: ["minutes"]))),
        .init(function: .init(name: "pause_focus", description: "提议暂停正在运行的专注，仅focus/running。", parameters: .init(properties: [:], required: []))),
        .init(function: .init(name: "resume_focus", description: "提议继续已暂停专注，仅focus/paused，不能开始休息。", parameters: .init(properties: [:], required: []))),
        .init(function: .init(name: "set_quiet", description: "提议设置手动安静明确目标，不能解除专注安静。", parameters: .init(properties: ["enabled": .init(type: "boolean", description: "手动安静目标值", minimum: nil, maximum: nil)], required: ["enabled"])))
    ]
}
