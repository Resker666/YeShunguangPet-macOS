import AppKit

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    weak var session: PetSession?
    let visibilityItem=NSMenuItem(title:"显示角色",action:#selector(toggle),keyEquivalent:"")
    let recallItem=NSMenuItem(title:"召回角色",action:#selector(recall),keyEquivalent:"")
    let settingsItem=NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:",")
    private(set) var settingsController: SettingsWindowController?
    let menu=NSMenu()
    private let persistenceItem=NSMenuItem(title:"",action:nil,keyEquivalent:"")
    private let retryItem=NSMenuItem(title:"重试保存设置",action:#selector(retry),keyEquivalent:"")
    private let resetItem=NSMenuItem(title:"备份原配置并重置",action:#selector(reset),keyEquivalent:"")
    private let onQuit: () -> Void
    init(session: PetSession?, error: String? = nil, onQuit: @escaping () -> Void) {
        self.session=session; self.onQuit=onQuit; item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        item.button?.image=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"叶瞬光桌宠")
        item.button?.toolTip="叶瞬光桌宠"; item.button?.setAccessibilityLabel("叶瞬光桌宠")
        menu.autoenablesItems=false
        if let error { let label=NSMenuItem(title:"加载失败：\(error)",action:nil,keyEquivalent:""); label.isEnabled=false; menu.addItem(label); menu.addItem(.separator()) }
        for entry in [visibilityItem,recallItem] { entry.target=self; menu.addItem(entry) }
        settingsItem.target=self; menu.addItem(settingsItem)
        persistenceItem.isEnabled=false
        for entry in [persistenceItem,retryItem,resetItem] { entry.target=self; menu.addItem(entry) }
        menu.addItem(.separator())
        let quit=NSMenuItem(title:"退出",action:#selector(quit),keyEquivalent:""); quit.target=self; menu.addItem(quit)
        menu.delegate=self; item.menu=menu
        session?.onStatusChange = { [weak self] in self?.refresh() }; refresh()
    }
    func refresh() {
        visibilityItem.title=session?.isVisible == true ? "隐藏角色" : "显示角色"; visibilityItem.isEnabled=session != nil; recallItem.isEnabled=session != nil
        settingsItem.isEnabled=session != nil; settingsController?.model.refresh()
        let message=session?.persistenceError
        persistenceItem.isHidden=message==nil; persistenceItem.title=session?.protectedSettings == true ? "原配置受保护，设置暂不保存" : "设置保存失败"; persistenceItem.toolTip=message
        retryItem.isHidden=message==nil || session?.protectedSettings == true
        resetItem.isHidden=session?.protectedSettings != true
    }
    @objc private func retry() { session?.retrySave(); refresh() }
    @objc private func reset() { session?.resetProtectedSettings(); refresh() }
    func menuWillOpen(_ menu: NSMenu) { session?.cancelInput(); refresh() }
    @objc private func toggle() { if let session { session.setVisible(!session.isVisible) }; refresh() }
    @objc private func recall() { session?.recall(); refresh() }
    @objc private func openSettings() {
        guard let session else { return }
        if settingsController == nil { settingsController=SettingsWindowController(session:session) }
        settingsController?.present()
    }
    @objc private func quit() { onQuit() }
    func dispose() { settingsController?.close(); settingsController=nil; item.menu=nil; menu.delegate=nil; NSStatusBar.system.removeStatusItem(item) }
}
