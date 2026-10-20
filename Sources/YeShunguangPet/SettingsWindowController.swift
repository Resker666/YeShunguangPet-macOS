import AppKit
import SwiftUI
import PetCore

@MainActor final class SettingsModel: ObservableObject {
    @Published private(set) var preferences: PetPreferences
    @Published private(set) var saveError: String?
    private weak var session: PetSession?
    init(session: PetSession) { self.session=session; preferences=session.preferences; saveError=session.persistenceError }
    func refresh() {
        guard let session else { return }
        preferences=session.preferences; saveError=session.persistenceError
    }
    func setScale(_ scale: Double) {
        var value=preferences; value.scale=scale; session?.setPreferences(value); refresh()
    }
    func setAlwaysOnTop(_ enabled: Bool) {
        var value=preferences; value.alwaysOnTop=enabled; session?.setPreferences(value); refresh()
    }
}

@MainActor final class SettingsWindowController: NSWindowController {
    let model: SettingsModel
    private weak var session: PetSession?
    init(session: PetSession) {
        self.session=session; model=SettingsModel(session:session)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:420,height:320),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="叶瞬光桌宠设置"; window.isReleasedWhenClosed=false
        window.contentViewController=NSHostingController(rootView:PetSettingsView(model:model))
        window.center()
        super.init(window:window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        session?.cancelInput(); model.refresh()
        showWindow(nil); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
}

private struct PetSettingsView: View {
    @ObservedObject var model: SettingsModel
    private var version: String {
        let info=Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "开发版")（\(info["CFBundleVersion"] as? String ?? "—")）"
    }
    private var architecture: String {
        #if arch(arm64)
        "Apple Silicon · arm64"
        #else
        "Intel · x86_64（实验版）"
        #endif
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("角色大小",value:"\(Int((model.preferences.scale*100).rounded()))%")
                Slider(value:Binding(get:{model.preferences.scale},set:{model.setScale($0)}),in:0.5...2,step:0.05) {
                    Text("角色大小")
                } minimumValueLabel: { Text("50%") } maximumValueLabel: { Text("200%") }
                .accessibilityIdentifier("pet-scale")
                Toggle("保持置顶",isOn:Binding(get:{model.preferences.alwaysOnTop},set:{model.setAlwaysOnTop($0)}))
                    .accessibilityIdentifier("pet-always-on-top")
                Text("修改立即生效并自动保存。关闭置顶后，角色可能被其他窗口遮挡，可从菜单栏召回。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error=model.saveError {
                Section {
                    Text("设置尚未保存").font(.headline)
                    Text(error).font(.caption).textSelection(.enabled)
                    Text("请从菜单栏重试保存；原配置受保护时，先选择“备份原配置并重置”。")
                        .font(.caption)
                }
            }
            Section {
                LabeledContent("版本",value:version)
                LabeledContent("架构",value:architecture)
            }
        }
        .formStyle(.grouped)
        .frame(width:420)
        .fixedSize(horizontal:false,vertical:true)
    }
}
