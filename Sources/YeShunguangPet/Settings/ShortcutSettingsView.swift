import SwiftUI
import PetCore

struct ShortcutSettingsView:View {
    @ObservedObject var controller:ShortcutController
    let onApplied:()->Void
    var body:some View {
        Form {
            Section {
                Text("组合键默认不绑定。至少选择两个修饰键，并包含 Control 或 Option。按键名称按美式物理键位标注。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ShortcutAction.allCases,id:\.self) {action in
                ShortcutEditorRow(controller:controller,action:action,onApplied:onApplied)
            }
            Section {
                Text("在其他应用中也可操作桌宠；菜单展开或确认对话框打开时暂停。系统可能拒绝已占用的组合键，未激活时可更改或重试。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
private struct ShortcutEditorRow:View {
    @ObservedObject var controller:ShortcutController
    let action:ShortcutAction
    let onApplied:()->Void
    @State private var key:UInt32=0
    @State private var modifiers:ShortcutModifiers=[.control,.option]
    private var status:ShortcutStatus? {controller.statuses[action]}
    private func toggle(_ flag:ShortcutModifiers)->Binding<Bool> {
        Binding(get:{modifiers.contains(flag)},set:{if $0{modifiers.insert(flag)}else{modifiers.remove(flag)}})
    }
    private func resetDraft(){key=status?.remembered?.keyCode ?? 0;modifiers=status?.remembered?.modifiers ?? [.control,.option]}
    var body:some View {
        Section(action.title) {
            Text(status?.remembered.map{"已保存：\($0.label)"} ?? "尚未绑定").font(.caption)
            HStack {
                Toggle("⌃ Control",isOn:toggle(.control))
                Toggle("⌥ Option",isOn:toggle(.option))
            }
            HStack {
                Toggle("⇧ Shift",isOn:toggle(.shift))
                Toggle("⌘ Command",isOn:toggle(.command))
            }
            Picker("按键（美式物理键位）",selection:$key) {ForEach(KeyboardShortcuts.keys){Text($0.label).tag($0.id)}}
            HStack {
                Button("应用") {controller.apply(.init(keyCode:key,modifiers:modifiers),to:action);onApplied()}
                Button("清除") {controller.apply(nil,to:action);onApplied()}
                Button("重试登记 / 释放") {controller.retry(action);onApplied()}
            }
            if let active=status?.active {Text("已激活：\(active.label)").font(.caption).foregroundStyle(.secondary)}
            else if status?.remembered != nil {Text("当前未激活").font(.caption).foregroundStyle(.orange)}
            if let pending=status?.pendingCleanup,!pending.isEmpty {
                Text("未保存，仍待释放：\(pending.map(\.label).joined(separator:"、"))").font(.caption).foregroundStyle(.red)
            }
            if let message=status?.message {Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
        }.onAppear{resetDraft()}.onChange(of:status?.remembered){_,_ in resetDraft()}
    }
}
