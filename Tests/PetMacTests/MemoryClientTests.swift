import Foundation
import XCTest
import PetCore

private final class MemoryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var finish = true
    nonisolated(unsafe) private static var origin: URL?
    nonisolated(unsafe) private static var contentType = "text/event-stream"
    nonisolated(unsafe) private static var requests = [URLRequest]()
    nonisolated(unsafe) private static var onStart: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var onStop: (@Sendable () -> Void)?
    private var stopObserver: (@Sendable () -> Void)?
    static func configure(_ data: Data, status: Int = 200, finish: Bool = true, origin: URL? = nil, contentType: String = "text/event-stream", onStart: (@Sendable () -> Void)? = nil, onStop: (@Sendable () -> Void)? = nil) {
        lock.withLock { Self.data = data; Self.status = status; Self.finish = finish; Self.origin = origin; Self.contentType = contentType; Self.onStart = onStart; Self.onStop = onStop; requests = [] }
    }
    static var recorded: [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.lock.withLock { Self.requests.append(request); stopObserver = Self.onStop; return (Self.data, Self.status, Self.finish, Self.origin, Self.contentType, Self.onStart) }
        let response = HTTPURLResponse(url: value.3 ?? request.url!, statusCode: value.1, httpVersion: nil, headerFields: ["Content-Type": value.4])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: value.0.count, by: 7) { client?.urlProtocol(self, didLoad: value.0.subdata(in: offset..<min(offset + 7, value.0.count))) }
        value.5?()
        if value.2 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        let observer = Self.lock.withLock { let value = stopObserver; stopObserver = nil; return value }
        observer?()
    }
}

final class MemoryClientTests: XCTestCase {
    private let valid = #"{"candidates":[{"text":"新的喜好","sourceRounds":[1]}]}"#
    private func snapshot() throws -> MemoryExtractionSnapshot {
        let conversation = try ChatConversation(characterID: "robin", profile: .init(background: "DO-NOT-SEND-PERSONA"), memories: [ChatMemory(text: "EXISTING-MEMORY")])
            .appending(user: "USER-SOURCE", assistant: "ASSISTANT-CONTEXT")
        return try MemoryExtractionSnapshot(conversation: conversation, model: .pro)
    }
    private func client() -> DeepSeekMemoryClient {
        let config = DeepSeekChatClient.configuration(); config.protocolClasses = [MemoryURLProtocol.self]
        return DeepSeekMemoryClient(configuration: config)
    }
    private func payload(_ content: String, reason: String = "stop", done: Bool = true) throws -> Data {
        let frame: [String: Any] = ["choices": [["index": 0, "delta": ["role": "assistant", "content": content], "finish_reason": reason]]]
        return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self) + "\n\n" + (done ? "data: [DONE]\n\n" : "")).utf8)
    }
    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var value = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; value.append(contentsOf: buffer.prefix(count)) }
            data = value
        } else { throw SkinError("missing test body") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testExtractionRequestUsesJSONModeAndFrozenSource() async throws {
        MemoryURLProtocol.configure(try payload(valid))
        let result = try await client().extract(snapshot(), apiKey: "TEST-ONLY-MEMORY-KEY")
        XCTAssertEqual(result.candidates.map(\.text), ["新的喜好"])
        XCTAssertEqual(result.candidates.first?.sourceRounds, [1])
        let request = try XCTUnwrap(MemoryURLProtocol.recorded.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST-ONLY-MEMORY-KEY")
        let body = try requestBody(request)
        XCTAssertEqual(body["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let text = messages.map { $0["content"] ?? "" }.joined()
        for expected in ["USER-SOURCE", "ASSISTANT-CONTEXT", "EXISTING-MEMORY"] { XCTAssertTrue(text.contains(expected)) }
        XCTAssertFalse(text.contains("DO-NOT-SEND-PERSONA"))
    }
    func testExtractionRejectsEmptyTruncatedInvalidAndOversizedResults() async throws {
        let oversized = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": [["text": String(repeating: "字", count: 5500), "sourceRounds": [1]]]]), as: UTF8.self)
        for response in [try payload(""), try payload(valid, done: false), try payload(valid, reason: "length"), try payload("broken"), try payload(#"{"candidates":[{"text":"bad","sourceRounds":[2]}]}"#), try payload(oversized)] {
            MemoryURLProtocol.configure(response)
            do { _ = try await client().extract(snapshot(), apiKey: "TEST"); XCTFail("invalid extraction accepted") } catch {}
            XCTAssertEqual(MemoryURLProtocol.recorded.count, 1)
        }
    }
    func testCancellationAndHTTPFailureNeverRetry() async throws {
        for status in [400, 401, 402, 422, 429, 500, 503, 302] {
            MemoryURLProtocol.configure(Data("SECRET-RESPONSE".utf8), status: status)
            do { _ = try await client().extract(snapshot(), apiKey: "TEST"); XCTFail("HTTP accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("SECRET-RESPONSE")) }
            XCTAssertEqual(MemoryURLProtocol.recorded.count, 1)
        }
        for (origin, type) in [(URL(string: "https://wrong.invalid")!, "text/event-stream"), (URL(string: "https://api.deepseek.com/chat/completions")!, "text/plain")] {
            MemoryURLProtocol.configure(try payload(valid), origin: origin, contentType: type)
            do { _ = try await client().extract(snapshot(), apiKey: "TEST"); XCTFail("source/type accepted") } catch {}
        }
        let started = expectation(description: "transport started"), stopped = expectation(description: "transport stopped")
        MemoryURLProtocol.configure(Data(), finish: false, onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        let transport = client(), input = try snapshot()
        let task = Task { try await transport.extract(input, apiKey: "TEST") }
        await fulfillment(of: [started], timeout: 3)
        task.cancel(); _ = await task.result
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(MemoryURLProtocol.recorded.count, 1)
    }
}
