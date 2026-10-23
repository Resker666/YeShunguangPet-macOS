import Foundation
import XCTest
import PetCore

private final class ActionURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var requests = [URLRequest]()
    nonisolated(unsafe) static var finish = true
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?
    private var stopObserver: (@Sendable () -> Void)?
    static func configure(_ data: Data, finish: Bool = true, onStop: (@Sendable () -> Void)? = nil) {
        lock.withLock { Self.data = data; requests = []; Self.finish = finish; Self.onStop = onStop }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.lock.withLock { Self.requests.append(request); stopObserver = Self.onStop; return (Self.data, Self.finish) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        for byte in value.0 { client?.urlProtocol(self, didLoad: Data([byte])) }
        if value.1 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { let observer = Self.lock.withLock { let result = stopObserver; stopObserver = nil; return result }; observer?() }
    static var recorded: [URLRequest] { lock.withLock { requests } }
}

final class ChatActionClientTests: XCTestCase {
    private func frame(_ delta: [String: Any] = [:], _ reason: String? = nil) throws -> String {
        let object: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": reason.map { $0 as Any } ?? NSNull()]]]
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }
    private func tool(_ arguments: String = "{\"minutes\":25}", name: String = "start_focus", id: String = "call_1", index: Any = 0) -> [String: Any] {
        ["index": index, "id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }
    private let done = "data: [DONE]\n\n"
    private func payload(_ item: [String: Any]? = nil, reason: String = "tool_calls") throws -> Data {
        Data(((try frame(["content": "", "tool_calls": [item ?? tool()]])) + (try frame([:], reason)) + done).utf8)
    }
    func testToolRoundCompletesOnlyAfterArgumentsAndDone() throws {
        let prefix = try frame(["content": "你😀，稍等。"]) + frame(["content": NSNull(), "tool_calls": [tool("{\"min")]]) + frame(["tool_calls": [["index": 0, "function": ["arguments": "utes\":25}"]]]]) + frame([:], "tool_calls")
        let data = Data((prefix + done).utf8)
        for split in 0...data.count {
            var decoder = ChatSSEDecoder(mode: .chatActions)
            let events = try decoder.append(Data(data.prefix(split))) + decoder.append(Data(data.dropFirst(split)))
            try decoder.finish()
            XCTAssertEqual(events, [.delta("你😀，稍等。"), .action(.startFocus(minutes: 25))])
        }
        var decoder = ChatSSEDecoder(mode: .chatActions)
        XCTAssertEqual(try decoder.append(Data(prefix.utf8)), [.delta("你😀，稍等。")])
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertEqual(try decoder.append(Data(done.utf8)), [.action(.startFocus(minutes: 25))])
        try decoder.finish()
        var textOnly = ChatSSEDecoder()
        XCTAssertThrowsError(try textOnly.append(try payload()))
        var boundary = ChatSSEDecoder(mode: .chatActions)
        XCTAssertEqual(try boundary.append(try payload(tool(id: String(repeating: "i", count: 256)))), [.action(.startFocus(minutes: 25))])
    }
    func testMalformedOrMultipleToolsNeverComplete() throws {
        var invalid = [Data]()
        for item in [tool(index: 1), tool(index: true), tool(index: 0.5), tool(name: "shell"), tool(id: ""), tool(id: "bad\n"), tool(id: String(repeating: "i", count: 257)), tool("{\"minutes\":true}"), tool("{\"minutes\":25,\"minutes\":26}"), tool(String(repeating: " ", count: 4097)), tool("broken")] {
            invalid.append(try payload(item))
        }
        invalid += [
            Data(((try frame(["tool_calls": [tool(), tool(id: "call_2")]])) + (try frame([:], "tool_calls")) + done).utf8),
            try payload(reason: "stop"),
            Data(((try frame([:], "tool_calls")) + done).utf8),
            Data(((try frame(["content": ""], "stop")) + done).utf8),
            Data(((try frame(["content": "答"], "stop")) + (try frame([:], "stop")) + done).utf8),
            Data(((try frame(["content": "答"], "stop")) + (try frame(["content": "晚到"])) + done).utf8)
        ]
        for conflict in [["id": "different"], ["type": "other"], ["function": ["name": "pause_focus"]]] as [[String: Any]] {
            var next = conflict; next["index"] = 0
            invalid.append(Data(((try frame(["tool_calls": [tool()]])) + (try frame(["tool_calls": [next]])) + (try frame([:], "tool_calls")) + done).utf8))
        }
        for data in invalid {
            var decoder = ChatSSEDecoder(mode: .chatActions)
            XCTAssertThrowsError(try decoder.append(data), String(decoding: data, as: UTF8.self))
        }
        var incomplete = ChatSSEDecoder(mode: .chatActions)
        _ = try incomplete.append(Data((try frame(["tool_calls": [tool()]])).utf8))
        XCTAssertThrowsError(try incomplete.finish())
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testRequestsSeparateActionsFromMemoryJSON() async throws {
        let configuration = DeepSeekChatClient.configuration(); configuration.protocolClasses = [ActionURLProtocol.self]
        let conversation = try ChatConversation(characterID: "robin").appending(user: "旧问题", assistant: "旧回答")
        let runtime = ChatAppSnapshot(focusRevision: 0, quietRevision: 0, phase: .focus, status: .ready, focusMinutes: 25, breakMinutes: 5, remainingSeconds: 1500, manualQuiet: false, focusQuiet: false)
        let snapshot = try ChatPromptSnapshot(characterID: "robin", characterName: "知更鸟", conversation: conversation, model: .flash, input: "专注25分钟", appSnapshot: runtime)
        ActionURLProtocol.configure(try payload())
        var events = [ChatStreamEvent]()
        for try await event in DeepSeekChatClient(configuration: configuration).stream(snapshot, apiKey: "TEST-ACTION-ONLY") { events.append(event) }
        XCTAssertEqual(events, [.action(.startFocus(minutes: 25))])
        let request = try XCTUnwrap(ActionURLProtocol.recorded.first), json = try body(request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual((json["tools"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(json["tool_choice"] as? String, "auto")
        XCTAssertNil(json["parallel_tool_calls"]); XCTAssertNil(json["response_format"])
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        ActionURLProtocol.configure(Data(((try frame(["content": "{\"candidates\":[]}"], "stop")) + done).utf8))
        _ = try await DeepSeekMemoryClient(configuration: configuration).extract(MemoryExtractionSnapshot(conversation: conversation, model: .flash), apiKey: "TEST-ACTION-ONLY")
        let memoryBody = try body(XCTUnwrap(ActionURLProtocol.recorded.first))
        XCTAssertNil(memoryBody["tools"]); XCTAssertNil(memoryBody["tool_choice"])
        XCTAssertEqual((memoryBody["response_format"] as? [String: String])?["type"], "json_object")
        ActionURLProtocol.configure(try payload(tool(index: 1)))
        do { for try await _ in DeepSeekChatClient(configuration: configuration).stream(snapshot, apiKey: "TEST-ACTION-ONLY") {}; XCTFail("invalid accepted") } catch {}
        XCTAssertEqual(ActionURLProtocol.recorded.count, 1)
        let stopped = expectation(description: "action transport stops after cancellation"), started = expectation(description: "preview received")
        ActionURLProtocol.configure(Data((try frame(["content": "预览"])).utf8), finish: false, onStop: { stopped.fulfill() })
        let task = Task { for try await event in DeepSeekChatClient(configuration: configuration).stream(snapshot, apiKey: "TEST-ACTION-ONLY") { if event == .delta("预览") { started.fulfill() } } }
        await fulfillment(of: [started], timeout: 3)
        task.cancel(); _ = await task.result
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(ActionURLProtocol.recorded.count, 1)
    }
}
