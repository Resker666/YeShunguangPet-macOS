import AppKit

@MainActor final class FocusMenus:NSObject {
    let menus=[NSMenu(),NSMenu()]
    private let presetMenus=[NSMenu(),NSMenu()]
    var trackingMenus:[NSMenu] {menus+presetMenus}
    private let focus:FocusController
    private weak var desktop:FocusWindowController?
    private let canDispatch:()->Bool,onSettings:()->Void
    private var disposed=false
    init(focus:FocusController,desktop:FocusWindowController?=nil,canDispatch:@escaping ()->Bool,onSettings:@escaping ()->Void) {
        self.focus=focus;self.desktop=desktop;self.canDispatch=canDispatch;self.onSettings=onSettings
        super.init()
        for (menu,presets) in zip(menus,presetMenus) {
            menu.autoenablesItems=false
            menu.addItem(NSMenuItem(title:"",action:nil,keyEquivalent:""))
            menu.addItem(primaryItem())
            let reset=NSMenuItem(title:"重置计时",action:#selector(reset),keyEquivalent:"");reset.target=self;menu.addItem(reset)
            menu.addItem(.separator())
            let settings=NSMenuItem(title:"专注设置…",action:#selector(settings),keyEquivalent:"");settings.target=self;menu.addItem(settings)
            menu.addItem(.separator())
            for (title,action) in [("显示桌面计时器",#selector(toggleDesktop)),("召回计时器",#selector(recallDesktop)),("计时器置顶",#selector(pinDesktop)),("重试保存计时器偏好",#selector(retryDesktop)),("紧凑计时窗",#selector(compactDesktop))] {
                let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
            }
            presets.autoenablesItems=false
            let quick=NSMenuItem(title:"快捷开始",action:nil,keyEquivalent:"");quick.submenu=presets;menu.addItem(quick)
            menu.addItem(NSMenuItem(title:"",action:nil,keyEquivalent:""))
            let retry=NSMenuItem(title:"重试保存专注统计",action:#selector(retryStatistics),keyEquivalent:"");retry.target=self;menu.addItem(retry)
            menu.addItem(NSMenuItem(title:"",action:nil,keyEquivalent:""))
        }
        desktop?.onPresentationChange={[weak self] in self?.refresh()}
        focus.onChange={[weak self] in self?.refresh()};refresh()
    }
    func refresh() {
        for (menu,presets) in zip(menus,presetMenus) {
            menu.items[0].title="\(focus.statusText) · \(focus.timeText)";menu.items[0].isEnabled=false
            if menu.items[1].representedObject as? FocusCommand != focus.primaryCommand {
                menu.removeItem(at:1);menu.insertItem(primaryItem(),at:1)
            }
            menu.items[1].isEnabled = !disposed && canDispatch()
            menu.items[2].isEnabled = !disposed && canDispatch() && focus.status != .ready
            menu.items[4].isEnabled = !disposed && canDispatch()
            for index in 6...10 {menu.items[index].isEnabled = !disposed && desktop != nil && canDispatch()}
            menu.items[6].state=desktop?.configuration.isVisible==true ? .on : .off
            menu.items[8].state=desktop?.configuration.alwaysOnTop==true ? .on : .off
            menu.items[10].state=desktop?.configuration.compact==true ? .on : .off
            menu.items[9].isHidden=desktop?.lastSaveError==nil;menu.items[9].toolTip=desktop?.lastSaveError
            menu.items[0].toolTip=focus.phase == .focus && focus.status == .running ? "注视、自动动作、走动和台词暂时暂停；手动安静开关保持原值。" : "每段完成后手动开始下一段。"
            menu.items[11].isEnabled = !disposed && canDispatch() && focus.canStartPreset
            if presets.items.first?.representedObject as? FocusPresetCommand != focus.presetCommand(minutes:15) {
                presets.removeAllItems()
                for minutes in FocusController.presetMinutes {
                    let item=NSMenuItem(title:"\(minutes) 分钟",action:#selector(preset(_:)),keyEquivalent:"")
                    item.target=self;item.representedObject=focus.presetCommand(minutes:minutes);presets.addItem(item)
                }
            }
            for item in presets.items{item.isEnabled = !disposed && canDispatch() && focus.canStartPreset}
            menu.items[12].title="今日 \(focus.todayStatistics.completedCount) 次 · \(focus.todayStatistics.plannedMinutes) 分钟（计划时长）";menu.items[12].isEnabled=false
            menu.items[13].isHidden=focus.statisticsSaveError==nil;menu.items[13].toolTip=focus.statisticsSaveError;menu.items[13].isEnabled = !disposed && canDispatch()
            menu.items[14].title="快捷开始未完成：\(focus.presetError ?? "")";menu.items[14].isHidden=focus.presetError==nil;menu.items[14].isEnabled=false
        }
    }
    private func primaryItem()->NSMenuItem {
        let item=NSMenuItem(title:focus.primaryTitle,action:#selector(performPrimary(_:)),keyEquivalent:"")
        item.target=self;item.representedObject=focus.primaryCommand;return item
    }
    @objc private func performPrimary(_ sender:NSMenuItem){guard !disposed,canDispatch(),let command=sender.representedObject as? FocusCommand else{return};focus.perform(command);refresh()}
    @objc private func reset(){guard !disposed,canDispatch() else{return};focus.reset();refresh()}
    @objc private func settings(){guard !disposed,canDispatch() else{return};onSettings()}
    @objc private func toggleDesktop(){guard !disposed,canDispatch(),let desktop else{return};desktop.setVisible(!desktop.configuration.isVisible)}
    @objc private func recallDesktop(){guard !disposed,canDispatch() else{return};desktop?.recall()}
    @objc private func pinDesktop(){guard !disposed,canDispatch(),let desktop else{return};desktop.setAlwaysOnTop(!desktop.configuration.alwaysOnTop)}
    @objc private func retryDesktop(){guard !disposed,canDispatch() else{return};desktop?.retrySave()}
    @objc private func compactDesktop(){guard !disposed,canDispatch(),let desktop else{return};desktop.setCompact(!desktop.configuration.compact)}
    @objc private func preset(_ sender:NSMenuItem){guard !disposed,canDispatch(),let command=sender.representedObject as? FocusPresetCommand else{return};focus.startPreset(command);refresh()}
    @objc private func retryStatistics(){guard !disposed,canDispatch() else{return};focus.retryStatisticsSaving();refresh()}
    func dispose(){disposed=true;focus.onChange=nil;desktop?.onPresentationChange=nil;for menu in trackingMenus{menu.cancelTracking();menu.delegate=nil;for item in menu.items{item.target=nil}}}
}
