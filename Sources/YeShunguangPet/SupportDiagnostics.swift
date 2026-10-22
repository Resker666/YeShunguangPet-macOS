import AppKit
import Combine
import PetCore

struct SupportDiagnosticSnapshot {
    struct Window {var frame:CGRect;var visible:Bool}
    enum ConfigurationStatus:String {case ready="未报告保存错误",protectedFile="原配置受保护",saveFailed="上次保存失败",unavailable="会话未启动"}
    enum SkinStatus:String {case bundled="内置皮肤",imported="导入副本",external="本次指定皮肤",fallback="已回退默认皮肤",unavailable="未加载"}
    var version="",build="",commit:String?
    var architecture=ReleaseArchitecture.arm64
    var systemVersion=OperatingSystemVersion(majorVersion:0,minorVersion:0,patchVersion:0)
    var screens=[CGRect](),pet:Window?,focus:Window?
    var configuration=ConfigurationStatus.unavailable,skin=SkinStatus.unavailable
    var positionLocked=false,quiet=false,statisticsSaveFailed=false,focusWindowSaveFailed=false
    func report()->String {
        let version=ReleaseVersion(tag:version)?.description ?? "未知"
        let build = !build.isEmpty && build.utf8.count<=12 && build.utf8.allSatisfy{(48...57).contains($0)} ? build : "未知"
        let commit=commit.flatMap{value in value.utf8.count==40 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)} ? value : nil} ?? "未知"
        let components=[systemVersion.majorVersion,systemVersion.minorVersion,systemVersion.patchVersion]
        let system=components.allSatisfy{(0...100_000).contains($0)} ? components.map(String.init).joined(separator:".") : "未知"
        func flag(_ value:Bool)->String {value ? "是" : "否"}
        func rectangle(_ r:CGRect)->String {
            let values=[r.origin.x,r.origin.y,r.width,r.height]
            guard values.allSatisfy({$0.isFinite && abs($0)<=1_000_000}),r.width>0,r.height>0 else{return "不可用"}
            return String(format:"x=%.1f, y=%.1f, w=%.1f, h=%.1f",locale:Locale(identifier:"en_US_POSIX"),Double(r.origin.x),Double(r.origin.y),Double(r.width),Double(r.height))
        }
        func window(_ value:Window?)->String {value.map{"可见=\(flag($0.visible))；\(rectangle($0.frame))"} ?? "未创建"}
        var lines=["叶瞬光桌宠诊断摘要","版本：\(version)；build：\(build)","构建提交：\(commit)","运行架构：\(architecture.rawValue)","macOS：\(system)","配置状态：\(configuration.rawValue)","皮肤状态：\(skin.rawValue)","角色窗口：\(window(pet))","计时窗口：\(window(focus))","位置锁定：\(flag(positionLocked))；当前安静：\(flag(quiet))","统计保存失败：\(flag(statisticsSaveFailed))；计时窗偏好保存失败：\(flag(focusWindowSaveFailed))","屏幕可用区域（逻辑点）："]
        for (index,rect) in screens.prefix(16).enumerated(){lines.append("屏幕\(index+1)：\(rectangle(rect))")}
        if screens.isEmpty{lines.append("暂无屏幕信息")}
        if screens.count>16{lines.append("仅列出前16块屏幕")}
        lines.append("不包含私人路径、个人台词、完整配置或原始错误；由用户手动生成。")
        return lines.joined(separator:"\n")
    }
    @MainActor static func capture(session:PetSession?,focusWindow:FocusWindowController?,bundle:Bundle = .main)->Self {
        var value=Self()
        value.version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
        value.build=bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""
        if let url=bundle.url(forResource:"build-info",withExtension:"json"),let file=try? FileHandle(forReadingFrom:url) {
            defer{try? file.close()}
            if let data=try? file.read(upToCount:4097),data.count<=4096,let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {value.commit=json["commit"] as? String}
        }
        #if arch(arm64)
        value.architecture = .arm64
        #else
        value.architecture = .x86_64
        #endif
        value.systemVersion=ProcessInfo.processInfo.operatingSystemVersion
        value.screens=session?.screens().map(\.visibleFrame) ?? NSScreen.screens.map(\.visibleFrame)
        if let session {
            value.configuration=session.protectedSettings ? .protectedFile : session.persistenceError == nil ? .ready : .saveFailed
            if session.skinWarning != nil {value.skin = .fallback}
            else if session.skin.directory==session.defaultSkin.directory {value.skin = .bundled}
            else if let id=session.selectedSkinID,session.skin.directory==session.library.directory.appendingPathComponent(id,isDirectory:true).resolvingSymlinksInPath() {value.skin = .imported}
            else {value.skin = .external}
            value.pet = .init(frame:session.panel.frame,visible:session.panel.isVisible)
            value.positionLocked=session.preferences.positionLocked;value.quiet=session.effectiveQuiet
            value.statisticsSaveFailed=session.focusStatisticsSaveError != nil
        }
        if let focusWindow {
            value.focus = .init(frame:focusWindow.panel.frame,visible:focusWindow.panel.isVisible)
            value.focusWindowSaveFailed=focusWindow.lastSaveError != nil
        }
        return value
    }
}

@MainActor final class SupportDiagnosticsModel:ObservableObject {
    enum Feedback:Equatable {
        case idle,copied,failed,blocked
        var message:String? {switch self {case .idle:return nil;case .copied:return "诊断信息已复制";case .failed:return "复制失败，请重试";case .blocked:return "当前暂不能复制，请关闭对话框或稍后重试"}}
    }
    @Published private(set) var feedback=Feedback.idle
    private let capture:()->SupportDiagnosticSnapshot,canCopy:()->Bool,writeReport:(String)->Bool
    init(capture:@escaping ()->SupportDiagnosticSnapshot,canCopy:@escaping ()->Bool,write:((String)->Bool)?=nil) {
        self.capture=capture;self.canCopy=canCopy
        self.writeReport=write ?? {Self.write($0,to:.general)}
    }
    func copyDiagnostics() {
        guard canCopy() else{feedback = .blocked;return}
        feedback=writeReport(capture().report()) ? .copied : .failed
    }
    static func write(_ text:String,to board:NSPasteboard)->Bool {board.clearContents();return board.setString(text,forType:.string)}
}
