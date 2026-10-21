import AppKit
import PetCore

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    let updates:ReleaseUpdateModel
    private(set) var shortcuts:ShortcutController?
    private let loginItem:LoginItemController?
    let skinModel:SettingsModel?
    let focus:FocusController?
    private var quickSkins:QuickSkinMenus?
    private var focusMenus:FocusMenus?
    private var openMenus=Set<ObjectIdentifier>(),terminating=false
    private var menuOpen:Bool { !openMenus.isEmpty }
    let checkUpdatesItem=NSMenuItem(title:"检查更新…",action:#selector(checkUpdates),keyEquivalent:"")
    private let item: NSStatusItem
    weak var session: PetSession?
    let visibilityItem=NSMenuItem(title:"显示角色",action:#selector(toggle),keyEquivalent:"")
    let recallItem=NSMenuItem(title:"召回角色",action:#selector(recall),keyEquivalent:"")
    let settingsItem=NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:",")
    let quietItem=NSMenuItem(title:"安静模式",action:#selector(toggleQuiet),keyEquivalent:"")
    private let lockItem=NSMenuItem(title:"锁定位置",action:#selector(toggleLock),keyEquivalent:"")
    private(set) var settingsController: SettingsWindowController?
    let menu=NSMenu()
    private let contextMenu=NSMenu()
    private let contextSettingsItem=NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:"")
    private let contextQuietItem=NSMenuItem(title:"安静模式",action:#selector(toggleQuiet),keyEquivalent:"")
    private let contextHideItem=NSMenuItem(title:"隐藏角色",action:#selector(toggle),keyEquivalent:"")
    private let waveItem=NSMenuItem(title:"挥手",action:#selector(wave),keyEquivalent:"")
    private let jumpItem=NSMenuItem(title:"跳跃",action:#selector(jump),keyEquivalent:"")
    private let contextLockItem=NSMenuItem(title:"锁定位置",action:#selector(toggleLock),keyEquivalent:"")
    private let persistenceItem=NSMenuItem(title:"",action:nil,keyEquivalent:"")
    private let retryItem=NSMenuItem(title:"重试保存设置",action:#selector(retry),keyEquivalent:"")
    private let resetItem=NSMenuItem(title:"备份原配置并重置",action:#selector(reset),keyEquivalent:"")
    let skinWarningItem=NSMenuItem(title:"皮肤恢复提示（查看设置…）",action:#selector(openSettings),keyEquivalent:"")
    private let onQuit: () -> Void
    init(session: PetSession?, error: String? = nil, updates:ReleaseUpdateModel?=nil,registry:(any HotKeyRegistry)?=nil,loginItem:LoginItemController?=nil, onQuit: @escaping () -> Void) {
        #if arch(arm64)
        let architecture=ReleaseArchitecture.arm64
        #else
        let architecture=ReleaseArchitecture.x86_64
        #endif
        self.updates=updates ?? ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? ReleaseVersion(tag:"0.1.15")!,architecture:architecture,client:ReleaseUpdateClient())
        self.loginItem=loginItem
        let focus=session.map{FocusController(session:$0)}
        self.focus=focus
        self.skinModel=session.map{SettingsModel(session:$0,loginItem:loginItem,focus:focus)}
        self.session=session; self.onQuit=onQuit; item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        if let session {
            shortcuts=ShortcutController(session:session,registry:registry ?? CarbonHotKeyRegistry(),canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.menuOpen && !self.terminating && self.settingsController?.hasBlockingSheet != true && NSApp.modalWindow==nil
            })
        }
        item.button?.image=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"叶瞬光桌宠")
        item.button?.toolTip="叶瞬光桌宠"; item.button?.setAccessibilityLabel("叶瞬光桌宠")
        menu.autoenablesItems=false
        if let error { let label=NSMenuItem(title:"加载失败：\(error)",action:nil,keyEquivalent:""); label.isEnabled=false; menu.addItem(label); menu.addItem(.separator()) }
        for entry in [visibilityItem,recallItem,quietItem,lockItem] { entry.target=self; menu.addItem(entry) }
        lockItem.toolTip="暂停拖动和自动走动，保留点击、召回及屏幕变化时的位置修正。"
        quietItem.toolTip="本次运行暂时暂停注视、自动动作和走动，保留待机与手动互动；重开恢复正常。"
        settingsItem.target=self; menu.addItem(settingsItem)
        checkUpdatesItem.target=self;menu.addItem(checkUpdatesItem)
        skinWarningItem.target=self; menu.addItem(skinWarningItem)
        persistenceItem.isEnabled=false
        for entry in [persistenceItem,retryItem,resetItem] { entry.target=self; menu.addItem(entry) }
        menu.addItem(.separator())
        let quit=NSMenuItem(title:"退出",action:#selector(quit),keyEquivalent:""); quit.target=self; menu.addItem(quit)
        menu.delegate=self; item.menu=menu
        contextMenu.autoenablesItems=false;contextMenu.delegate=self
        for entry in [contextSettingsItem,contextQuietItem,contextLockItem,contextHideItem,waveItem,jumpItem] {entry.target=self;contextMenu.addItem(entry)}
        contextQuietItem.toolTip=quietItem.toolTip
        contextLockItem.toolTip=lockItem.toolTip
        if let session,let skinModel {
            let skins=QuickSkinMenus(session:session,model:skinModel,canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.terminating && self.session?.gate.exiting==false && self.settingsController?.hasBlockingSheet != true && NSApp.modalWindow==nil
            },onManage:{[weak self] in self?.presentSettings(tab:.skin)})
            quickSkins=skins
            for (parent,child) in zip([menu,contextMenu],skins.menus) {
                let entry=NSMenuItem(title:"切换皮肤",action:nil,keyEquivalent:"");entry.submenu=child;parent.insertItem(entry,at:0);child.delegate=self
            }
        }
        if let focus {
            let menus=FocusMenus(focus:focus,canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.terminating && self.session?.gate.exiting==false && self.settingsController?.hasBlockingSheet != true && NSApp.modalWindow==nil
            },onSettings:{[weak self] in self?.presentSettings(tab:.focus)})
            focusMenus=menus
            for (parent,child) in zip([menu,contextMenu],menus.menus) {
                let entry=NSMenuItem(title:"专注计时",action:nil,keyEquivalent:"");entry.submenu=child;parent.insertItem(entry,at:1);child.delegate=self
            }
        }
        session?.view.contextMenu = { [weak self] in
            guard let self,!self.terminating,self.session?.gate.shouldRunFrames==true,self.settingsController?.hasBlockingSheet != true,NSApp.modalWindow==nil else{return nil}
            self.refresh();return self.contextMenu
        }
        session?.onStatusChange = { [weak self] in self?.refresh() }; refresh()
    }
    func refresh() {
        visibilityItem.title=session?.isVisible == true ? "隐藏角色" : "显示角色"; visibilityItem.isEnabled=session != nil; recallItem.isEnabled=session != nil
        checkUpdatesItem.isEnabled=session != nil
        settingsItem.isEnabled=session != nil; skinModel?.refresh();focus?.refreshConfiguration()
        quietItem.isEnabled=session != nil;quietItem.state=session?.isQuiet == true ? .on : .off
        contextQuietItem.state=quietItem.state
        lockItem.isEnabled=session != nil && !terminating;lockItem.state=session?.preferences.positionLocked==true ? .on : .off;contextLockItem.state=lockItem.state
        for entry in contextMenu.items {entry.isEnabled=session != nil && !terminating && session?.gate.exiting != true}
        skinWarningItem.isHidden=session?.skinWarning==nil; skinWarningItem.toolTip=session?.skinWarning
        let message=session?.persistenceError
        persistenceItem.isHidden=message==nil; persistenceItem.title=session?.protectedSettings == true ? "原配置受保护，设置暂不保存" : "设置保存失败"; persistenceItem.toolTip=message
        retryItem.isHidden=message==nil || session?.protectedSettings == true
        resetItem.isHidden=session?.protectedSettings != true
        quickSkins?.refresh()
        focusMenus?.refresh()
    }
    @objc private func retry() { session?.retrySave(); refresh() }
    @objc private func reset() { session?.resetProtectedSettings(); refresh() }
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu || menu === contextMenu || quickSkins?.menus.contains(where:{$0 === menu})==true || focusMenus?.menus.contains(where:{$0 === menu})==true else{return}
        openMenus.insert(ObjectIdentifier(menu));session?.setMenuOpen(true);refresh()
        focus?.setDisplayVisible(true,source:"menus")
        quickSkins?.reload()
    }
    func menuDidClose(_ menu: NSMenu) {
        openMenus.remove(ObjectIdentifier(menu));session?.setMenuOpen(menuOpen)
        focus?.setDisplayVisible(menuOpen,source:"menus")
    }
    @objc private func wave() {guard !terminating else{return};session?.play(.waving)}
    @objc private func jump() {guard !terminating else{return};session?.play(.jumping)}
    @objc private func toggle() { if let session { session.setVisible(!session.isVisible) }; refresh() }
    @objc private func recall() { session?.recall(); refresh() }
    @objc private func toggleQuiet() { if let session {session.setQuiet(!session.isQuiet)};refresh() }
    @objc private func toggleLock() {
        guard !terminating,let session else{return}
        var prefs=session.preferences;prefs.positionLocked.toggle();session.setPreferences(prefs);refresh()
    }
    @objc private func openSettings() {presentSettings()}
    private func presentSettings(tab:SettingsTab?=nil) {
        guard let session,let shortcuts else { return }
        if settingsController == nil { settingsController=SettingsWindowController(session:session,updates:updates,shortcuts:shortcuts,loginItem:loginItem,model:skinModel) }
        settingsController?.present(tab:tab)
    }
    @objc private func checkUpdates() {guard session != nil else{return};presentSettings(tab:.about);updates.check()}
    func startShortcuts(){shortcuts?.start()}
    func beginTermination(){terminating=true;focus?.setTerminating(true);contextMenu.cancelTracking();updates.cancel();quickSkins?.cancel();if let settingsController{settingsController.beginTermination()}else{skinModel?.beginTermination()};refresh()}
    func cancelTermination(){terminating=false;focus?.setTerminating(false);skinModel?.cancelTermination();refresh()}
    @objc private func quit() { onQuit() }
    func dispose() { terminating=true;focus?.dispose();focusMenus?.dispose();focusMenus=nil;contextMenu.cancelTracking();quickSkins?.dispose();quickSkins=nil;session?.view.contextMenu=nil;contextMenu.delegate=nil;openMenus.removeAll();updates.cancel();shortcuts?.dispose();settingsController?.close(); settingsController=nil; session?.setMenuOpen(false); item.menu=nil; menu.delegate=nil; NSStatusBar.system.removeStatusItem(item) }
}
