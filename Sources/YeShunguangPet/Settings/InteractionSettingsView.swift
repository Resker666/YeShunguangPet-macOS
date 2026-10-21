import SwiftUI

struct InteractionSettingsView:View {
    @ObservedObject var model:SettingsModel
    var body:some View {
        Form {
            Section("鼠标注视") {
                Toggle("注视鼠标",isOn:Binding(get:{model.preferences.lookAtMouse},set:{model.setLookAtMouse($0)}))
                    .accessibilityIdentifier("pet-look-at-mouse")
                Text(model.gazeAvailable ? "关闭设置窗口后，鼠标靠近时会短暂注视。菜单、点击和拖动期间暂停。" : "此皮肤未提供注视帧；偏好会保留，切换到支持的皮肤后生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("互动台词") {
                Toggle("显示互动台词",isOn:Binding(get:{model.preferences.speechEnabled},set:{model.setSpeechEnabled($0)}))
                    .accessibilityIdentifier("pet-speech-enabled")
                Text("默认关闭。单击或拖动结束时回应，约6秒后收起，至少间隔30秒；计时完成可单独提醒。个人台词优先，其次皮肤台词和默认文案。安静或专注运行时暂停互动台词。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("个人台词") {PersonalSpeechEditor(model:model).id(model.speechEditGeneration)}
            Section("自动小动作") {
                Toggle("空闲时自动做动作",isOn:Binding(get:{model.preferences.automaticActions},set:{model.setAutomaticActions($0)}))
                    .accessibilityIdentifier("pet-automatic-actions")
                LabeledContent("动作间隔",value:"约 \(model.preferences.automaticActionIntervalSeconds) 秒")
                Slider(value:Binding(get:{Double(model.preferences.automaticActionIntervalSeconds)},set:{model.setAutomaticActionInterval(Int($0.rounded()))}),in:15...120,step:5) {
                    Text("动作间隔")
                } minimumValueLabel: { Text("15 秒") } maximumValueLabel: { Text("120 秒") }
                .disabled(!model.preferences.automaticActions)
                .accessibilityIdentifier("pet-automatic-action-interval")
                Text("默认关闭。开启后按皮肤规则做动作，间隔有 ±25% 浮动；旧皮肤使用挥手或跳跃。点击、拖动、菜单和设置期间暂停，关闭此窗口后开始等待。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("桌面走动") {
                Toggle("空闲时走动一小段",isOn:Binding(get:{model.preferences.desktopRoaming},set:{model.setDesktopRoaming($0)}))
                    .accessibilityIdentifier("pet-desktop-roaming")
                LabeledContent("走动间隔",value:"约 \(model.preferences.roamIntervalSeconds) 秒")
                Slider(value:Binding(get:{Double(model.preferences.roamIntervalSeconds)},set:{model.setRoamInterval(Int($0.rounded()))}),in:20...180,step:5) {
                    Text("走动间隔")
                } minimumValueLabel: { Text("20 秒") } maximumValueLabel: { Text("180 秒") }
                .disabled(!model.preferences.desktopRoaming)
                .accessibilityIdentifier("pet-roam-interval")
                Text(model.roamingAvailable ? "默认关闭，间隔有 ±25% 浮动，每次约60–120点。鼠标靠近时停下；点击、拖动、菜单和设置会结束本次走动。走完自动保存位置。" : "此皮肤缺少左右循环行走动画；偏好会保留，换到支持的皮肤后生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.preferences.positionLocked {
                    Text("位置已锁定，自动走动暂停；解除锁定后按原间隔重新等待。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}
