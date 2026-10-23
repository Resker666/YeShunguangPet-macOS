import Foundation
import PetCore

protocol ChatStreaming: Sendable {
    func stream(_ snapshot: ChatPromptSnapshot, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

private final class ChatRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DeepSeekChatClient: ChatStreaming {
    private struct Body: Encodable {
        struct Thinking: Encodable { let type = "disabled" }
        let model: String
        let messages: [ChatMessage]
        let stream = true
        let thinking = Thinking()
        let max_tokens = 2048
    }
    private let sessionConfiguration: URLSessionConfiguration
    static func configuration() -> URLSessionConfiguration {
        let result = URLSessionConfiguration.ephemeral
        result.urlCache = nil; result.requestCachePolicy = .reloadIgnoringLocalCacheData
        result.httpCookieStorage = nil; result.httpShouldSetCookies = false
        result.timeoutIntervalForRequest = 30; result.timeoutIntervalForResource = 120
        return result
    }
    init(configuration: URLSessionConfiguration = DeepSeekChatClient.configuration()) {
        sessionConfiguration = configuration.copy() as! URLSessionConfiguration
    }

    func stream(_ snapshot: ChatPromptSnapshot, apiKey: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        return AsyncThrowingStream { continuation in
            let worker = Task.detached {
                let session = URLSession(configuration: configuration, delegate: ChatRedirectDelegate(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    try Task.checkCancellation()
                    let key = try ChatSecret.normalize(apiKey)
                    let data = try JSONEncoder().encode(Body(model: snapshot.model.rawValue, messages: snapshot.messages))
                    guard data.count <= 1048576 else { throw SkinError("本次聊天请求超过允许大小。") }
                    var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                    request.httpMethod = "POST"; request.httpBody = data
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.url == request.url else { throw SkinError("AI 响应来源无效。") }
                    guard http.statusCode == 200 else { throw Self.httpError(http.statusCode) }
                    guard response.expectedContentLength <= 1048576 else { throw SkinError("AI 响应超过允许大小。") }
                    guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw SkinError("AI 服务没有返回流式文字，未自动重新请求。")
                    }
                    var decoder = ChatSSEDecoder(), buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if byte == 10 || buffer.count >= 4096 {
                            for event in try decoder.append(buffer) {
                                try Task.checkCancellation()
                                continuation.yield(event)
                                if event == .completed { continuation.finish(); return }
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        for event in try decoder.append(buffer) { continuation.yield(event) }
                    }
                    try Task.checkCancellation()
                    try decoder.finish()
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch let error as SkinError { continuation.finish(throwing: error) }
                catch let error as URLError where error.code == .cancelled { continuation.finish(throwing: CancellationError()) }
                catch let error as URLError where error.code == .timedOut { continuation.finish(throwing: SkinError("AI 请求超时，可手动重试。")) }
                catch { continuation.finish(throwing: SkinError("AI 连接未完成，请检查网络后手动重试。")) }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    private static func httpError(_ status: Int) -> SkinError {
        switch status {
        case 400, 422: return SkinError("AI 请求参数被拒绝，请检查模型设置。")
        case 401: return SkinError("DeepSeek 认证失败，请重新保存 API 密钥。")
        case 402: return SkinError("DeepSeek 账户余额不足，请检查账户。")
        case 429: return SkinError("DeepSeek 请求受限，请稍后手动重试。")
        case 500, 503: return SkinError("DeepSeek 服务暂时不可用，请稍后手动重试。")
        default: return SkinError("AI 请求失败（HTTP \(status)），可手动重试。")
        }
    }
}
