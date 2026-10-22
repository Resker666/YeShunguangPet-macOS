import AppKit
import SwiftUI

enum SettingsTab:String,CaseIterable {case skin,general,interaction,focus,shortcuts,about,help}
struct SettingsTabsView:View {
    @ObservedObject var model:SettingsModel
    @ObservedObject var updates:ReleaseUpdateModel
    @ObservedObject var shortcuts:ShortcutController
    @ObservedObject var login:LoginItemController
    @ObservedObject var diagnostics:SupportDiagnosticsModel
    let onChooseSkin:()->Void
    var body:some View {
        VStack(spacing:0) {
            TabView(selection:$model.selectedTab) {
                SkinSettingsView(model:model,onChooseSkin:onChooseSkin).tabItem{Label("皮肤",systemImage:"pawprint")}.tag(SettingsTab.skin)
                GeneralSettingsView(model:model,login:login).tabItem{Label("通用",systemImage:"gearshape")}.tag(SettingsTab.general)
                InteractionSettingsView(model:model).tabItem{Label("互动",systemImage:"hand.wave")}.tag(SettingsTab.interaction)
                FocusSettingsView(focus:model.focus).tabItem{Label("专注",systemImage:"timer")}.tag(SettingsTab.focus)
                ShortcutSettingsView(controller:shortcuts,onApplied:{model.refresh()}).id(model.shortcutEditGeneration).tabItem{Label("快捷键",systemImage:"keyboard")}.tag(SettingsTab.shortcuts)
                AboutSettingsView(updates:updates,diagnostics:diagnostics,onHelp:{model.selectedTab = .help}).tabItem{Label("关于",systemImage:"info.circle")}.tag(SettingsTab.about)
                HelpSettingsView(diagnostics:diagnostics).tabItem{Label("帮助",systemImage:"questionmark.circle")}.tag(SettingsTab.help)
            }
            if let error=model.saveError {
                VStack(alignment:.leading,spacing:4) {
                    Text("设置尚未保存").font(.headline)
                    Text(error).font(.caption).textSelection(.enabled)
                    Text("可从菜单栏重试；原配置受保护时先备份并重置。").font(.caption)
                }.frame(maxWidth:.infinity,alignment:.leading).padding().background(.quaternary)
            }
        }
        .disabled(model.isTerminating)
        .overlay{RoundedRectangle(cornerRadius:10).stroke(model.isDropTargeted ? Color.accentColor : .clear,lineWidth:3).padding(3).allowsHitTesting(false)}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in login.refresh()}
    }
}
