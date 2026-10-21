import AppKit
import SwiftUI
import PetCore

struct AboutSettingsView:View {
    @ObservedObject var updates:ReleaseUpdateModel
    private var architecture:String {updates.architecture == .arm64 ? "Apple Silicon · arm64" : "Intel · x86_64（实验版）"}
    var body:some View {
        Form {
            Section("叶瞬光桌宠") {
                LabeledContent("当前版本",value:updates.currentVersion.description)
                LabeledContent("架构",value:architecture)
                Text("Swift + AppKit 原生桌宠。程序许可与素材声明随 App 提供。").font(.caption).foregroundStyle(.secondary)
            }
            Section("手动检查更新") {
                Button("检查更新") {updates.check()}.disabled(updates.state == .checking)
                Text("仅点击时匿名查询本项目的 GitHub 公开版本；下载按钮在浏览器中打开，不会自动安装。").font(.caption).foregroundStyle(.secondary)
                switch updates.state {
                case .idle:Text("尚未检查。").foregroundStyle(.secondary)
                case .checking:HStack{ProgressView().controlSize(.small);Text("正在查询 GitHub…")}
                case .failure(let message):Text(message).foregroundStyle(.red).textSelection(.enabled)
                case .success(let info,let comparison):
                    LabeledContent("公开版本",value:info.version.description)
                    Text(comparison == .newer ? "发现新版本。" : comparison == .current ? "当前版本与公开版本相同。" : "当前开发版本高于公开版本，无需更新。")
                    Button("查看官方发布页") {_=NSWorkspace.shared.open(info.pageURL)}
                    if let url=info.downloadURL {
                        Button(comparison == .ahead ? "公开版安装包（\(info.version.description)，较旧）" : "下载 \(updates.architecture.rawValue) 安装包") {_=NSWorkspace.shared.open(url)}
                    }else{Text("此公开版本尚无 \(updates.architecture.rawValue) DMG，可在发布页查看其他附件。").font(.caption).foregroundStyle(.secondary)}
                    if !info.notes.isEmpty {Text(info.notes).font(.body).textSelection(.enabled)}
                }
            }
        }.formStyle(.grouped)
    }
}
