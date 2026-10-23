import Foundation
import PetCore

enum ChatStreamEvent: Equatable, Sendable { case delta(String), completed, action(ChatAction) }

struct ChatSSEDecoder {
    enum Mode { case textOnly, chatActions }
    private let mode: Mode
    init(mode: Mode = .textOnly) { self.mode = mode }
    private struct Tool: Decodable {
        struct Function: Decodable { let name: String?; let arguments: String? }
        let index: Int
        let id: String?
        let type: String?
        let function: Function?
    }
    private var toolID: String?, toolName: String?, toolType: String?
    private var arguments = "", hasTool = false, finishReason: String?

    private struct Frame: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String?; let role: String?; let tool_calls: [Tool]? }
            let index: Int
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]
    }
    private var line = Data(), fields = [String](), eventBytes = 0, totalBytes = 0
    private var answer = "", stopped = false, completed = false

    mutating func append(_ data: Data) throws -> [ChatStreamEvent] {
        guard data.count <= 1048576 - totalBytes else { throw SkinError("AI 响应超过允许大小。") }
        totalBytes += data.count
        var events = [ChatStreamEvent]()
        for byte in data {
            if completed { break }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                guard let text = String(data: line, encoding: .utf8) else { throw SkinError("AI 流含有无效文字编码。") }
                line.removeAll(keepingCapacity: true)
                if text.isEmpty {
                    events += try finishEvent()
                } else if !completed, text == "data" || text.hasPrefix("data:") {
                    var value = text == "data" ? "" : String(text.dropFirst(5))
                    if value.first == " " { value.removeFirst() }
                    eventBytes += value.utf8.count + 1
                    guard eventBytes <= 65536 else { throw SkinError("AI 流事件超过允许大小。") }
                    fields.append(value)
                }
            } else {
                guard line.count < 65536 else { throw SkinError("AI 流数据行超过允许大小。") }
                line.append(byte)
            }
        }
        return events
    }

    private mutating func finishEvent() throws -> [ChatStreamEvent] {
        guard !fields.isEmpty else { return [] }
        let value = fields.joined(separator: "\n")
        fields.removeAll(keepingCapacity: true); eventBytes = 0
        if completed { return [] }
        if value == "[DONE]" {
            guard stopped else { throw SkinError("AI 回复未完整结束，可手动重试。") }
            if finishReason == "tool_calls" {
                guard mode == .chatActions, hasTool, toolID != nil, toolType == "function", let toolName else { throw SkinError("操作提议未完整结束。") }
                let action = try ChatActionDecoder.decode(name: toolName, arguments: Data(arguments.utf8))
                completed = true
                return [.action(action)]
            }
            try ChatText.validate(answer, maxUTF16: 8000, allowEmpty: false)
            completed = true
            return [.completed]
        }
        do {
            let data = Data(value.utf8)
            try StrictJSON.validate(data)
            let frame = try JSONDecoder().decode(Frame.self, from: data)
            if frame.choices.isEmpty { return [] }
            guard frame.choices.filter({ $0.index == 0 }).count == 1,
                  let choice = frame.choices.first(where: { $0.index == 0 }),
                  choice.delta?.role == nil || choice.delta?.role == "assistant" else { throw SkinError("AI 流响应无效。") }
            guard !stopped || (choice.finish_reason == nil && choice.delta?.role == nil && choice.delta?.content == nil && choice.delta?.tool_calls == nil) else { throw SkinError("AI 结束标记后仍有载荷。") }
            if let tools = choice.delta?.tool_calls {
                guard mode == .chatActions, tools.count == 1, let tool = tools.first, tool.index == 0 else { throw SkinError("每轮只允许一个有效操作提议。") }
                // JSONDecoder accepts integral floating-point values as Int; verify the wire type too.
                let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let choices = raw?["choices"] as? [[String: Any]]
                let delta = choices?.first(where: { ($0["index"] as? Int) == 0 })?["delta"] as? [String: Any]
                let calls = delta?["tool_calls"] as? [[String: Any]]
                guard let index = calls?.first?["index"] as? NSNumber,
                      !["c", "d", "f"].contains(String(cString: index.objCType)) else { throw SkinError("操作索引无效。") }
                hasTool = true
                try merge(tool.id, into: &toolID)
                try merge(tool.type, into: &toolType)
                try merge(tool.function?.name, into: &toolName)
                if let id = toolID {
                    guard !id.isEmpty, id.utf16.count <= 256, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SkinError("操作标识无效。") }
                }
                if let type = toolType, type != "function" { throw SkinError("操作类型无效。") }
                if let name = toolName, !["start_focus", "pause_focus", "resume_focus", "set_quiet"].contains(name) { throw SkinError("操作名称无效。") }
                if let fragment = tool.function?.arguments {
                    guard fragment.utf8.count <= 4096 - arguments.utf8.count else { throw SkinError("操作参数超长。") }
                    arguments += fragment
                }
            }
            var events = [ChatStreamEvent]()
            if let content = choice.delta?.content, !content.isEmpty {
                guard !stopped, answer.utf16.count + content.utf16.count <= 8000 else { throw SkinError("AI 回复超长或已被截断。") }
                answer += content; events.append(.delta(content))
            }
            if let reason = choice.finish_reason {
                guard !stopped, (reason == "stop" && !hasTool) || (reason == "tool_calls" && mode == .chatActions && hasTool) else { throw SkinError("AI 回复被截断或操作结束无效，未记入聊天记录。") }
                finishReason = reason; stopped = true
            }
            return events
        } catch let error as SkinError { throw error }
        catch { throw SkinError("AI 流响应无法解析，未记入聊天记录。") }
    }

    private func merge(_ fragment: String?, into value: inout String?) throws {
        guard let fragment else { return }
        guard value == nil || value == fragment else { throw SkinError("操作分片资料冲突。") }
        value = fragment
    }

    func finish() throws {
        guard completed else { throw SkinError("AI 连接提前结束，未记入聊天记录。") }
    }
}
