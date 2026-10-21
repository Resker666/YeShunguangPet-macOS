import SwiftUI
import ServiceManagement

struct GeneralSettingsView:View {
    @ObservedObject var model:SettingsModel
    @ObservedObject var login:LoginItemController
    var body:some View {
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
            Section("位置") {
                Toggle("拖动后贴边",isOn:Binding(get:{model.preferences.snapToEdges},set:{model.setSnapToEdges($0)}))
                    .accessibilityIdentifier("pet-snap-to-edges")
                Text("正常拖动松手时，距当前屏幕可用边缘 12 点内自动贴齐。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("锁定位置",isOn:Binding(get:{model.preferences.positionLocked},set:{model.setPositionLocked($0)}))
                    .accessibilityIdentifier("pet-position-locked")
                Text("暂停拖动和自动走动；单击、双击、召回及屏幕变化时的位置修正仍可用。也可从角色右键或菜单栏解除锁定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时启动",isOn:Binding(get:{login.isSelected},set:{login.setEnabled($0)}))
                    .disabled(!login.canEnable && !login.isSelected)
                    .accessibilityIdentifier("pet-launch-at-login")
                Text(login.statusText).font(.caption).foregroundStyle(.secondary)
                if !login.canEnable && !login.isSelected {
                    Text("请先将 App 安装到“应用程序”，再开启登录时启动。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if login.status == .requiresApproval {
                    Button("打开登录项设置") {login.openSystemSettings()}
                }
                if let error=login.lastError {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            }
        }.formStyle(.grouped)
    }
}
