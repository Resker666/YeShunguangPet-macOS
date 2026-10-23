import Foundation
import PetCore

enum ChatStreamEvent: Equatable, Sendable { case delta(String), completed }

struct ChatSSEDecoder {
    private struct Frame: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String?; let role: String? }
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
            var events = [ChatStreamEvent]()
            if let content = choice.delta?.content, !content.isEmpty {
                guard !stopped, answer.utf16.count + content.utf16.count <= 8000 else { throw SkinError("AI 回复超长或已被截断。") }
                answer += content; events.append(.delta(content))
            }
            if let reason = choice.finish_reason {
                guard reason == "stop" else { throw SkinError("AI 回复被截断或中止，未记入聊天记录。") }
                stopped = true
            }
            return events
        } catch let error as SkinError { throw error }
        catch { throw SkinError("AI 流响应无法解析，未记入聊天记录。") }
    }

    func finish() throws {
        guard completed else { throw SkinError("AI 连接提前结束，未记入聊天记录。") }
    }
}
