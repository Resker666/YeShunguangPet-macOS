import Foundation
import PetCore

protocol ChatMemoryExtracting: Sendable {
    func extract(_ snapshot: MemoryExtractionSnapshot, apiKey: String) async throws -> MemoryCandidateBatch
}

struct DeepSeekMemoryClient: ChatMemoryExtracting {
    private let transport: DeepSeekTextTransport
    init(configuration: URLSessionConfiguration = DeepSeekTextTransport.configuration()) {
        transport = DeepSeekTextTransport(configuration: configuration)
    }
    func extract(_ snapshot: MemoryExtractionSnapshot, apiKey: String) async throws -> MemoryCandidateBatch {
        var content = "", completed = false
        for try await event in transport.stream(model: snapshot.model, messages: snapshot.messages, format: .jsonObject, apiKey: apiKey) {
            try Task.checkCancellation()
            switch event {
            case .delta(let text):
                guard content.utf8.count + text.utf8.count <= 16384 else { throw SkinError("提炼结果超过限制，未保存记忆。") }
                content += text
            case .completed: completed = true
            case .action: throw SkinError("记忆提炼不能包含操作提议。")
            }
        }
        try Task.checkCancellation()
        guard completed else { throw SkinError("提炼尚未完整结束，未保存记忆。") }
        return try MemoryCandidateDecoder.decode(Data(content.utf8), for: snapshot)
    }
}
