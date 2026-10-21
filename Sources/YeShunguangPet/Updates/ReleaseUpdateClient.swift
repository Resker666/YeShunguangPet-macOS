import Foundation
import PetCore

protocol ReleaseFetching:Sendable {
    func fetchLatest(architecture:ReleaseArchitecture)async throws->ReleaseInfo
}
private final class ReleaseRedirectDelegate:NSObject,URLSessionTaskDelegate,Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping @Sendable (URLRequest?)->Void) {completionHandler(nil)}
}
struct ReleaseUpdateClient:ReleaseFetching {
    private let sessionConfiguration:URLSessionConfiguration
    static func configuration()->URLSessionConfiguration {
        let c=URLSessionConfiguration.ephemeral
        c.urlCache=nil;c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage=nil;c.httpShouldSetCookies=false
        c.timeoutIntervalForRequest=15;c.timeoutIntervalForResource=20
        return c
    }
    init(configuration:URLSessionConfiguration=ReleaseUpdateClient.configuration()) {sessionConfiguration=configuration.copy() as! URLSessionConfiguration}
    func fetchLatest(architecture:ReleaseArchitecture)async throws->ReleaseInfo {
        let session=URLSession(configuration:sessionConfiguration,delegate:ReleaseRedirectDelegate(),delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        var request=URLRequest(url:URL(string:"https://api.github.com/repos/Resker666/YeShunguangPet-macOS/releases/latest")!,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
        request.httpMethod="GET"
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("2026-03-10",forHTTPHeaderField:"X-GitHub-Api-Version")
        request.setValue("YeShunguangPet-macOS",forHTTPHeaderField:"User-Agent")
        let (bytes,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse else{throw SkinError("更新服务器返回了无效响应，请重试。")}
        guard http.url==request.url else{throw SkinError("更新响应来源不匹配，请重试。")}
        switch http.statusCode {
        case 200:break
        case 403,429:throw SkinError("GitHub 暂时限制了查询，请稍后重试。")
        case 404:throw SkinError("尚无可用的公开版本，请稍后重试。")
        default:throw SkinError("更新查询失败（HTTP \(http.statusCode)），请重试。")
        }
        guard response.expectedContentLength<=1_048_576 else{throw SkinError("更新响应超过 1 MiB，请稍后重试。")}
        var data=Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count<1_048_576 else{throw SkinError("更新响应超过 1 MiB，请稍后重试。")}
            data.append(byte)
        }
        try Task.checkCancellation()
        return try ReleaseInfo.parse(data,architecture:architecture)
    }
}
