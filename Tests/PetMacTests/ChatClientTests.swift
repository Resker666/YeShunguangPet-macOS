import Foundation
import XCTest
import PetCore

private final class ChatURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var finish = true
    nonisolated(unsafe) private static var failure: URLError?
    nonisolated(unsafe) private static var responseURL: URL?
    nonisolated(unsafe) private static var requests = [URLRequest]()
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var onStop: (@Sendable () -> Void)?
    private var stopObserver: (@Sendable () -> Void)?
    static func configure(data: Data, status: Int = 200, finish: Bool = true, failure: URLError? = nil, responseURL: URL? = nil, onStop: (@Sendable () -> Void)? = nil) {
        lock.withLock { body = data; Self.status = status; Self.finish = finish; Self.failure = failure; Self.responseURL = responseURL; Self.onStop = onStop; requests = []; stopped = 0 }
    }
    static var recorded: [URLRequest] { lock.withLock { requests } }
    static var stopCount: Int { lock.withLock { stopped } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let values = Self.lock.withLock { stopObserver = Self.onStop; Self.requests.append(request); return (Self.body, Self.status, Self.finish, Self.failure, Self.responseURL) }
        if let error = values.3 { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: values.4 ?? request.url!, statusCode: values.1, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: values.0.count, by: 7) {
            client?.urlProtocol(self, didLoad: values.0.subdata(in: offset..<min(offset + 7, values.0.count)))
        }
        if values.2 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        let observer = Self.lock.withLock {
            Self.stopped += 1
            let observer = stopObserver; stopObserver = nil
            return observer
        }
        observer?()
    }
}

final class ChatClientTests: XCTestCase {
    private func frame(_ content: String?, finish: String? = nil) throws -> String {
        var delta: [String: Any] = ["role": "assistant"]
        if let content { delta["content"] = content }
        let object: [String: Any] = [
            "id": "test", "object": "chat.completion.chunk", "created": 0, "model": "deepseek-flash",
            "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12]
        ]
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\r\n\r\n"
    }
    private func payload() throws -> Data {
        Data((": keep-alive\r\n\r\n" + (try frame("你😀")) + "data: {\"choices\":[]}\r\n\r\n" + (try frame("好", finish: "stop")) + "data: [DONE]\r\n\r\n").utf8)
    }
    private func snapshot() throws -> ChatPromptSnapshot {
        try ChatPromptSnapshot(characterID: "robin", characterName: "知更鸟", conversation: .init(characterID: "robin"), model: .flash, input: "你好")
    }
    private func client() -> DeepSeekChatClient {
        let config = DeepSeekChatClient.configuration()
        config.protocolClasses = [ChatURLProtocol.self]
        return DeepSeekChatClient(configuration: config)
    }
    private func collect(_ client: DeepSeekChatClient) async throws -> [ChatStreamEvent] {
        var result = [ChatStreamEvent]()
        for try await event in client.stream(try snapshot(), apiKey: "TEST-ONLY-KEY") { result.append(event) }
        return result
    }

    func testOfficialRequestContract() async throws {
        ChatURLProtocol.configure(data: try payload())
        let events = try await collect(client())
        XCTAssertEqual(events, [.delta("你😀"), .delta("好"), .completed])
        let request = try XCTUnwrap(ChatURLProtocol.recorded.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST-ONLY-KEY")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
            data = bytes
        } else { throw NSError(domain: "MissingRequestBody", code: 1) }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(body["tools"]); XCTAssertNil(body["user_id"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] ?? "" }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"], "你好")
        let config = DeepSeekChatClient.configuration()
        XCTAssertEqual(config.timeoutIntervalForRequest, 30); XCTAssertEqual(config.timeoutIntervalForResource, 120)
        XCTAssertNil(config.urlCache); XCTAssertNil(config.httpCookieStorage); XCTAssertFalse(config.httpShouldSetCookies)
    }

    func testSSEAllByteBoundariesAndCompletion() throws {
        let data = try payload()
        for split in 0...data.count {
            var decoder = ChatSSEDecoder()
            let first = try decoder.append(Data(data.prefix(split)))
            let second = try decoder.append(Data(data.dropFirst(split)))
            try decoder.finish()
            XCTAssertEqual(first + second, [.delta("你😀"), .delta("好"), .completed], "split \(split)")
        }
        var decoder = ChatSSEDecoder(), events = [ChatStreamEvent]()
        for byte in data { events += try decoder.append(Data([byte])) }
        try decoder.finish()
        XCTAssertEqual(events, [.delta("你😀"), .delta("好"), .completed])
    }

    func testSSERejectsTruncationAndLimits() throws {
        var incomplete = ChatSSEDecoder()
        _ = try incomplete.append(Data((try frame("半条")).utf8))
        XCTAssertThrowsError(try incomplete.finish())
        for reason in ["length", "content_filter", "tool_calls", "insufficient_system_resource", "aborted"] {
            var decoder = ChatSSEDecoder()
            XCTAssertThrowsError(try decoder.append(Data(((try frame("半条", finish: reason)) + "data: [DONE]\n\n").utf8)))
        }
        for data in [
            Data("data: [DONE]\n\n".utf8),
            Data("data: {broken}\n\n".utf8),
            Data([100, 97, 116, 97, 58, 32, 255, 10, 10]),
            Data(("data: " + String(repeating: "x", count: 65537)).utf8),
            Data(((try frame(String(repeating: "字", count: 8001), finish: "stop")) + "data: [DONE]\n\n").utf8),
            Data(((try frame(nil, finish: "stop")) + "data: [DONE]\n\n").utf8)
        ] { var decoder = ChatSSEDecoder(); XCTAssertThrowsError(try decoder.append(data)) }
        var large = ChatSSEDecoder()
        let keepAlive = Data((":" + String(repeating: "x", count: 60000) + "\n\n").utf8)
        XCTAssertThrowsError(try { for _ in 0..<18 { _ = try large.append(keepAlive) } }())
        var event = ChatSSEDecoder()
        XCTAssertThrowsError(try { for _ in 0..<70 { _ = try event.append(Data(("data: " + String(repeating: " ", count: 1000) + "\n").utf8)) } }())
    }

    func testCancellationAndHTTPFailuresNeverRetry() async throws {
        for status in [400, 401, 402, 422, 429, 500, 503, 302] {
            ChatURLProtocol.configure(data: Data("SECRET-ERROR-BODY".utf8), status: status)
            do { _ = try await collect(client()); XCTFail("HTTP \(status) accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("SECRET-ERROR-BODY")) }
            XCTAssertEqual(ChatURLProtocol.recorded.count, 1)
        }
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            ChatURLProtocol.configure(data: Data(), failure: URLError(code))
            do { _ = try await collect(client()); XCTFail("transport failure accepted") } catch {}
            XCTAssertEqual(ChatURLProtocol.recorded.count, 1)
        }
        ChatURLProtocol.configure(data: try payload(), responseURL: URL(string: "https://wrong.invalid/chat/completions")!)
        do { _ = try await collect(client()); XCTFail("wrong response source accepted") } catch {}
        let stopped = expectation(description: "URLSession stopped the active transport")
        ChatURLProtocol.configure(data: Data((try frame("开始")).utf8), finish: false, onStop: { stopped.fulfill() })
        let transport = client(), started = expectation(description: "first content arrived")
        let request = try snapshot()
        let task = Task {
            for try await event in transport.stream(request, apiKey: "TEST-ONLY-KEY") {
                if event == .delta("开始") { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        _ = await task.result
        // Ending the consumer does not join the detached URLSession worker.
        // Await the actual callback, with a time bound rather than a scheduler-iteration budget.
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertGreaterThan(ChatURLProtocol.stopCount, 0)
        XCTAssertEqual(ChatURLProtocol.recorded.count, 1)
    }
}
