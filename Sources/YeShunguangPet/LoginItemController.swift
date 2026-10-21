import AppKit
import Combine
import ServiceManagement

@MainActor final class LoginItemController:ObservableObject {
    @Published private(set) var status=SMAppService.Status.notRegistered
    @Published private(set) var lastError:String?
    private let bundleURL:URL
    private let readStatus:()->SMAppService.Status
    private let registerService:()throws->Void,unregisterService:()throws->Void
    var isSelected:Bool {status == .enabled || status == .requiresApproval}
    var canEnable:Bool {
        let app=bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let roots=[URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return app.pathExtension=="app" && roots.contains{app.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path+"/")}
    }
    var statusText:String {
        switch status {
        case .notRegistered:return "未启用登录时启动。"
        case .enabled:return "已启用，下次登录时自动打开。"
        case .requiresApproval:return "已登记，需在系统设置中允许后才能登录启动。"
        case .notFound:return "尚未找到已登记的登录项，可在安装后尝试开启。"
        @unknown default:return "无法识别系统返回的登录项状态。"
        }
    }
    init(bundleURL:URL=Bundle.main.bundleURL,status:@escaping ()->SMAppService.Status={SMAppService.mainApp.status},register:@escaping ()throws->Void={try SMAppService.mainApp.register()},unregister:@escaping ()throws->Void={try SMAppService.mainApp.unregister()}) {
        self.bundleURL=bundleURL;readStatus=status;registerService=register;unregisterService=unregister;refresh()
    }
    func refresh() {status=readStatus()}
    func setEnabled(_ enabled:Bool) {
        lastError=nil;refresh()
        if enabled==isSelected{return}
        guard !enabled || canEnable else{lastError="请先将 App 安装到“应用程序”，再开启登录时启动。";return}
        do {if enabled{try registerService()}else{try unregisterService()}}
        catch {lastError="\(enabled ? "开启" : "关闭")登录启动失败：\(error.localizedDescription)"}
        refresh()
    }
    func openSystemSettings() {SMAppService.openSystemSettingsLoginItems()}
}
