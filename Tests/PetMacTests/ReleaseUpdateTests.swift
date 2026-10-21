import Foundation
import XCTest
import PetCore

private final class UpdateURLProtocol:URLProtocol,@unchecked Sendable {
    private static let lock=NSLock()
    nonisolated(unsafe) private static var handler:(@Sendable (URLRequest)throws->(URLResponse,Data))?
    nonisolated(unsafe) private static var requests=[URLRequest]()
    nonisolated(unsafe) private static var finish=true
    nonisolated(unsafe) private static var stopped=0
    static func configure(finish:Bool=true,_ handler:@escaping @Sendable (URLRequest)throws->(URLResponse,Data)) {lock.withLock{Self.handler=handler;requests=[];Self.finish=finish;stopped=0}}
    static var stopCount:Int {lock.withLock{stopped}}
    static var recorded:[URLRequest] {lock.withLock{requests}}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let handler=Self.lock.withLock {Self.requests.append(request);return Self.handler}
        do {
            let (response,data)=try handler!(request)
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            for offset in stride(from:0,to:data.count,by:4096) {client?.urlProtocol(self,didLoad:data.subdata(in:offset..<min(offset+4096,data.count)))}
            if Self.lock.withLock({Self.finish}) {client?.urlProtocolDidFinishLoading(self)}
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {Self.lock.withLock{Self.stopped+=1}}
}
private actor ControlledReleaseClient:ReleaseFetching {
    private var replies=[Int:CheckedContinuation<ReleaseInfo,Error>]()
    private var waiters=[(Int,CheckedContinuation<Void,Never>)]()
    private(set) var count=0
    func fetchLatest(architecture:ReleaseArchitecture)async throws->ReleaseInfo {
        try await withCheckedThrowingContinuation { continuation in
            let index=count;count+=1;replies[index]=continuation
            let ready=waiters.filter{$0.0<=count};waiters.removeAll{$0.0<=count}
            ready.forEach{$0.1.resume()}
        }
    }
    func waitForRequests(_ number:Int)async {if count<number {await withCheckedContinuation{waiters.append((number,$0))}}}
    func complete(_ index:Int,result:Result<ReleaseInfo,Error>) {replies.removeValue(forKey:index)?.resume(with:result)}
}
@MainActor final class ReleaseUpdateTests:XCTestCase {
    private func payload(tag:String="v0.1.12")->Data {Data("{\"tag_name\":\"\(tag)\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://github.com/Resker666/YeShunguangPet-macOS/releases/tag/\(tag)\",\"body\":\"hello\",\"assets\":[]}".utf8)}
    private func client(status:Int=200,headers:[String:String]=[:],data:Data)->ReleaseUpdateClient {
        UpdateURLProtocol.configure {request in (HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!,data)}
        let c=ReleaseUpdateClient.configuration();c.protocolClasses=[UpdateURLProtocol.self]
        return ReleaseUpdateClient(configuration:c)
    }
    private func settle(_ model:ReleaseUpdateModel)async {
        for _ in 0..<10000 {if model.state != .checking{return};await Task.yield()}
        XCTFail("check did not settle")
    }
    func testManualOnlyDedupAndStaleCompletion()async throws {
        for staleFails in [false,true] {
            let transport=ControlledReleaseClient()
            let model=ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:"0.1.12")!,architecture:.arm64,client:transport)
            let initial=await transport.count;XCTAssertEqual(initial,0)
            model.check();model.check();await transport.waitForRequests(1)
            let one=await transport.count;XCTAssertEqual(one,1)
            model.cancel();model.check();await transport.waitForRequests(2)
            let info=try ReleaseInfo.parse(payload(tag:"v0.1.13"),architecture:.arm64)
            await transport.complete(1,result:.success(info));await settle(model)
            XCTAssertEqual(model.state,.success(info,.newer))
            await transport.complete(0,result:staleFails ? .failure(URLError(.timedOut)) : .success(try ReleaseInfo.parse(payload(),architecture:.arm64)))
            for _ in 0..<20 {await Task.yield()}
            XCTAssertEqual(model.state,.success(info,.newer))
        }
    }
    func testBoundedTransportAndRedirects()async throws {
        for headers in [["Content-Length":"1048577"],[:],["Content-Length":"10"]] {
            let transport=client(headers:headers,data:Data(repeating:32,count:1_048_577))
            do {_=try await transport.fetchLatest(architecture:.arm64);XCTFail("oversized response accepted")} catch {XCTAssertTrue(error.localizedDescription.contains("1 MiB"))}
        }
        var exact=payload();exact.append(Data(repeating:32,count:1_048_576-exact.count))
        let accepted=try await client(data:exact).fetchLatest(architecture:.arm64);XCTAssertEqual(accepted.version.description,"0.1.12")
        do {_=try await client(status:302,headers:["Location":"https://evil.invalid/"],data:Data()).fetchLatest(architecture:.arm64);XCTFail("redirect accepted")} catch {}
        XCTAssertEqual(UpdateURLProtocol.recorded.count,1)
    }
    func testTaskCancellationStopsUnderlyingRequest()async throws {
        UpdateURLProtocol.configure(finish:false){request in (HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,Data())}
        let c=ReleaseUpdateClient.configuration();c.protocolClasses=[UpdateURLProtocol.self]
        let transport=ReleaseUpdateClient(configuration:c)
        let task=Task{try await transport.fetchLatest(architecture:.arm64)}
        for _ in 0..<10000 {if !UpdateURLProtocol.recorded.isEmpty{break};await Task.yield()}
        XCTAssertEqual(UpdateURLProtocol.recorded.count,1)
        task.cancel()
        do {_=try await task.value;XCTFail("cancelled request succeeded")} catch {}
        for _ in 0..<10000 {if UpdateURLProtocol.stopCount>0{break};await Task.yield()}
        XCTAssertGreaterThan(UpdateURLProtocol.stopCount,0)
    }
    func testTransportContractAndFailures()async throws {
        let config=ReleaseUpdateClient.configuration()
        XCTAssertEqual(config.timeoutIntervalForRequest,15);XCTAssertEqual(config.timeoutIntervalForResource,20)
        XCTAssertNil(config.urlCache);XCTAssertNil(config.httpCookieStorage);XCTAssertFalse(config.httpShouldSetCookies)
        _=try await client(data:payload()).fetchLatest(architecture:.arm64)
        let request=try XCTUnwrap(UpdateURLProtocol.recorded.first)
        XCTAssertEqual(request.url?.absoluteString,"https://api.github.com/repos/Resker666/YeShunguangPet-macOS/releases/latest")
        XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-GitHub-Api-Version"),"2026-03-10")
        XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"));XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
        for status in [403,429,404,500] {
            do {_=try await client(status:status,data:Data()).fetchLatest(architecture:.arm64);XCTFail("HTTP \(status) accepted")} catch {XCTAssertFalse(error.localizedDescription.isEmpty)}
        }
        do {_=try await client(data:Data("broken".utf8)).fetchLatest(architecture:.arm64);XCTFail("bad JSON accepted")} catch {}
        for code in [URLError.Code.timedOut,.notConnectedToInternet,.cancelled] {
            UpdateURLProtocol.configure{_ in throw URLError(code)}
            let c=ReleaseUpdateClient.configuration();c.protocolClasses=[UpdateURLProtocol.self]
            do {_=try await ReleaseUpdateClient(configuration:c).fetchLatest(architecture:.arm64);XCTFail("transport error accepted")} catch {}
        }
        UpdateURLProtocol.configure{request in (URLResponse(url:request.url!,mimeType:nil,expectedContentLength:0,textEncodingName:nil),Data())}
        let c=ReleaseUpdateClient.configuration();c.protocolClasses=[UpdateURLProtocol.self]
        do {_=try await ReleaseUpdateClient(configuration:c).fetchLatest(architecture:.arm64);XCTFail("non HTTP accepted")} catch {}
    }
}
