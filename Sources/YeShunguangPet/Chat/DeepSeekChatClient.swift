import Foundation
import PetCore

protocol ChatStreaming: Sendable {
    func stream(_ snapshot: ChatPromptSnapshot, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

struct DeepSeekChatClient: ChatStreaming {
    private let transport: DeepSeekTextTransport
    static func configuration() -> URLSessionConfiguration { DeepSeekTextTransport.configuration() }
    init(configuration: URLSessionConfiguration = DeepSeekChatClient.configuration()) {
        transport = DeepSeekTextTransport(configuration: configuration)
    }
    func stream(_ snapshot: ChatPromptSnapshot, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        transport.stream(model: snapshot.model, messages: snapshot.messages, format: snapshot.appSnapshot == nil ? .text : .chatActions, apiKey: apiKey)
    }
}
