import AppKit

@MainActor final class FocusMenus:NSObject {
    let menus=[NSMenu(),NSMenu()]
    private let focus:FocusController
    private let canDispatch:()->Bool,onSettings:()->Void
    private var disposed=false
    init(focus:FocusController,canDispatch:@escaping ()->Bool,onSettings:@escaping ()->Void) {
        self.focus=focus;self.canDispatch=canDispatch;self.onSettings=onSettings
        super.init()
        for menu in menus {
            menu.autoenablesItems=false
            menu.addItem(NSMenuItem(title:"",action:nil,keyEquivalent:""))
            let primary=NSMenuItem(title:"",action:#selector(toggle),keyEquivalent:"");primary.target=self;menu.addItem(primary)
            let reset=NSMenuItem(title:"重置计时",action:#selector(reset),keyEquivalent:"");reset.target=self;menu.addItem(reset)
            menu.addItem(.separator())
            let settings=NSMenuItem(title:"专注设置…",action:#selector(settings),keyEquivalent:"");settings.target=self;menu.addItem(settings)
        }
        focus.onChange={[weak self] in self?.refresh()};refresh()
    }
    func refresh() {
        for menu in menus {
            menu.items[0].title="\(focus.statusText) · \(focus.timeText)";menu.items[0].isEnabled=false
            menu.items[1].title=focus.primaryTitle;menu.items[1].isEnabled = !disposed && canDispatch()
            menu.items[2].isEnabled = !disposed && canDispatch() && focus.status != .ready
            menu.items[4].isEnabled = !disposed && canDispatch()
            menu.items[0].toolTip=focus.phase == .focus && focus.status == .running ? "注视、自动动作、走动和台词暂时暂停；手动安静开关保持原值。" : "每段完成后手动开始下一段。"
        }
    }
    @objc private func toggle(){guard !disposed,canDispatch() else{return};if focus.status == .running{focus.pause()}else{focus.startOrResume()};refresh()}
    @objc private func reset(){guard !disposed,canDispatch() else{return};focus.reset();refresh()}
    @objc private func settings(){guard !disposed,canDispatch() else{return};onSettings()}
    func dispose(){disposed=true;focus.onChange=nil;for menu in menus{menu.cancelTracking();menu.delegate=nil;for item in menu.items{item.target=nil}}}
}
