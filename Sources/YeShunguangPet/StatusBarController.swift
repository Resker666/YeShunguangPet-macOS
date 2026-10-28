import AppKit
import PetCore

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    let updates:ReleaseUpdateModel
    private(set) var shortcuts:ShortcutController?
    private let loginItem:LoginItemController?
    let skinModel:SettingsModel?
    private(set) var chat:ChatController?
    private(set) var chatWindow:ChatWindowController?
    private(set) var chatPresentation:ChatPresentationCoordinator?
    private(set) var quickChatWindow:QuickChatWindowController?
    let quickChatItem=NSMenuItem(title:"快速聊天…",action:#selector(openQuickChat),keyEquivalent:"")
    private let contextQuickChatItem=NSMenuItem(title:"快速聊天…",action:#selector(openQuickChat),keyEquivalent:"")
    let chatItem=NSMenuItem(title:"完整聊天…",action:#selector(openChat),keyEquivalent:"")
    private let contextChatItem=NSMenuItem(title:"完整聊天…",action:#selector(openChat),keyEquivalent:"")
    let focus:FocusController?
    private(set) var focusWindow:FocusWindowController?
    private var quickSkins:QuickSkinMenus?
    private var focusMenus:FocusMenus?
    private var openMenus=Set<ObjectIdentifier>(),terminating=false
    private var voiceSheets = Set<ObjectIdentifier>()
    private var menuOpen:Bool { !openMenus.isEmpty }
    let checkUpdatesItem=NSMenuItem(title:"检查更新…",action:#selector(checkUpdates),keyEquivalent:"")
    let helpItem=NSMenuItem(title:"使用帮助…",action:#selector(openHelp),keyEquivalent:"")
    let copyDiagnosticsItem=NSMenuItem(title:"复制诊断信息",action:#selector(copyDiagnostics),keyEquivalent:"")
    private let diagnosticResultItem=NSMenuItem(title:"",action:nil,keyEquivalent:"")
    private(set) var diagnostics:SupportDiagnosticsModel?
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
    init(session: PetSession?, error: String? = nil, updates:ReleaseUpdateModel?=nil,registry:(any HotKeyRegistry)?=nil,loginItem:LoginItemController?=nil,diagnosticWriter:((String)->Bool)?=nil, chat:ChatController?=nil, onQuit: @escaping () -> Void) {
        #if arch(arm64)
        let architecture=ReleaseArchitecture.arm64
        #else
        let architecture=ReleaseArchitecture.x86_64
        #endif
        self.updates=updates ?? ReleaseUpdateModel(currentVersion:ReleaseVersion(tag:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? ReleaseVersion(tag:"0.1.20")!,architecture:architecture,client:ReleaseUpdateClient())
        self.loginItem=loginItem
        let focus=session.map{FocusController(session:$0)}
        self.focus=focus
        self.skinModel=session.map{SettingsModel(session:$0,loginItem:loginItem,focus:focus)}
        self.session=session; self.onQuit=onQuit; item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        if let session {
            if let chat { self.chat=chat }
            else {
                let actionBridge=FocusChatActionBridge(session:session,focus:focus!,canDispatch:{ [weak self] in self?.canUseSupportCommands == true })
                self.chat=ChatController(persistence:ChatArchiveWorker(settingsURL:session.settings.url),credentials:KeychainChatCredentialStore(),client:DeepSeekChatClient(),memoryClient:DeepSeekMemoryClient(),actions:actionBridge,canDispatch:{ [weak self] in self?.canUseSupportCommands == true },onFeedback:{ [weak self] text in self?.presentChatReply(text) })
            }
            if chat == nil {
                let worker = Bundle.main.resourceURL!.appendingPathComponent("LocalVoice/worker.py")
                let local = LocalVoiceOutput(dataRoot: session.settings.url.deletingLastPathComponent(), workerURL: worker)
                self.chat?.configureVoice(services: VoiceServices(input: NativeSpeechInput(), routing: VoiceOutputRouter(system: NativeSpeechOutput(), local: local)), now: session.now)
            }
            if let controller=self.chat {
                let presentation=ChatPresentationCoordinator(controller:controller,onPresented:{ [weak session] in session?.setChatPresented($0) },canPresent:{[weak self] in self?.canUseSupportCommands == true})
                chatPresentation=presentation
                let full=ChatWindowController(controller:controller,onPresentationChange:{_ in})
                let quick=QuickChatWindowController(controller:controller,session:session,onExpand:{[weak self,weak presentation] in guard self?.canUseSupportCommands == true else{return};presentation?.present(.full)},canDispatch:{[weak self] in self?.canUseSupportCommands == true})
                full.onQuickChat = {[weak self,weak presentation] in guard self?.canUseSupportCommands == true else{return};presentation?.present(.quick)}
                quick.onVoiceSettings = {[weak self,weak full,weak presentation] in
                    guard self?.canUseSupportCommands == true else{return}
                    presentation?.present(.full)
                    if presentation?.activeMode == .full, full?.isPresentationVisible == true { full?.selectPage(4) }
                }
                presentation.onVoicePresentationChanged = {[weak self] _ in self?.refreshVoiceEnvironment()}
                chatWindow=full;quickChatWindow=quick
                presentation.register(full,for:.full);presentation.register(quick,for:.quick)
            }
        }
        focus?.canPlayCompletionSound = {[weak self] in
            guard let self else{return false}
            return !self.terminating && self.session?.gate.exiting==false && self.settingsController?.hasBlockingSheet != true && self.chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil
        }
        focus?.allowsCompletionAudio = {[weak self] in self?.chat?.voice?.suppressesCompletionAudio != true}
        if let session {
            shortcuts=ShortcutController(session:session,registry:registry ?? CarbonHotKeyRegistry(),canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.menuOpen && !self.terminating && self.settingsController?.hasBlockingSheet != true && self.chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil
            })
        }
        item.button?.image=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"叶瞬光桌宠")
        item.button?.toolTip="叶瞬光桌宠"; item.button?.setAccessibilityLabel("叶瞬光桌宠")
        menu.autoenablesItems=false
        if let error { let label=NSMenuItem(title:"加载失败：\(error)",action:nil,keyEquivalent:""); label.isEnabled=false; menu.addItem(label); menu.addItem(.separator()) }
        for entry in [visibilityItem,recallItem,quietItem,lockItem] { entry.target=self; menu.addItem(entry) }
        lockItem.toolTip="暂停拖动和自动走动，保留点击、召回及屏幕变化时的位置修正。"
        quietItem.toolTip="本次运行暂时暂停注视、自动动作和走动，保留待机与手动互动；重开恢复正常。"
        quickChatItem.target=self; menu.addItem(quickChatItem)
        chatItem.target=self; menu.addItem(chatItem)
        settingsItem.target=self; menu.addItem(settingsItem)
        checkUpdatesItem.target=self;menu.addItem(checkUpdatesItem)
        helpItem.target=self;menu.addItem(helpItem)
        copyDiagnosticsItem.target=self;menu.addItem(copyDiagnosticsItem)
        diagnosticResultItem.isEnabled=false;menu.addItem(diagnosticResultItem)
        skinWarningItem.target=self; menu.addItem(skinWarningItem)
        persistenceItem.isEnabled=false
        for entry in [persistenceItem,retryItem,resetItem] { entry.target=self; menu.addItem(entry) }
        menu.addItem(.separator())
        let quit=NSMenuItem(title:"退出",action:#selector(quit),keyEquivalent:""); quit.target=self; menu.addItem(quit)
        menu.delegate=self; item.menu=menu
        contextMenu.autoenablesItems=false;contextMenu.delegate=self
        for entry in [contextQuickChatItem,contextChatItem,contextSettingsItem,contextQuietItem,contextLockItem,contextHideItem,waveItem,jumpItem] {entry.target=self;contextMenu.addItem(entry)}
        contextQuietItem.toolTip=quietItem.toolTip
        contextLockItem.toolTip=lockItem.toolTip
        if let session,let skinModel {
            let skins=QuickSkinMenus(session:session,model:skinModel,canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.terminating && self.session?.gate.exiting==false && self.settingsController?.hasBlockingSheet != true && self.chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil
            },onManage:{[weak self] in self?.presentSettings(tab:.skin)})
            quickSkins=skins
            for (parent,child) in zip([menu,contextMenu],skins.menus) {
                let entry=NSMenuItem(title:"切换皮肤",action:nil,keyEquivalent:"");entry.submenu=child;parent.insertItem(entry,at:0);child.delegate=self
            }
        }
        if let focus,let session {
            let window=FocusWindowController(session:session,focus:focus,canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.terminating && self.session?.gate.exiting==false && self.settingsController?.hasBlockingSheet != true && self.chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil
            })
            focusWindow=window
            let menus=FocusMenus(focus:focus,desktop:window,canDispatch:{[weak self] in
                guard let self else{return false}
                return !self.terminating && self.session?.gate.exiting==false && self.settingsController?.hasBlockingSheet != true && self.chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil
            },onSettings:{[weak self] in self?.presentSettings(tab:.focus)})
            focusMenus=menus;for tracked in menus.trackingMenus{tracked.delegate=self}
            for (parent,child) in zip([menu,contextMenu],menus.menus) {
                let entry=NSMenuItem(title:"专注计时",action:nil,keyEquivalent:"");entry.submenu=child;parent.insertItem(entry,at:1);child.delegate=self
            }
        }
        session?.view.contextMenu = { [weak self] in
            guard let self,!self.terminating,self.session?.gate.shouldRunFrames==true,self.settingsController?.hasBlockingSheet != true,self.chatPresentation?.hasBlockingSheet != true,NSApp.modalWindow==nil else{return nil}
            self.refresh();return self.contextMenu
        }
        diagnostics=SupportDiagnosticsModel(capture:{[weak self] in SupportDiagnosticSnapshot.capture(session:self?.session,focusWindow:self?.focusWindow)},canCopy:{[weak self] in self?.canUseSupportCommands==true},write:diagnosticWriter)
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self,selector:#selector(voiceWindowChanged),name:name,object:nil)
        }
        session?.onStatusChange = { [weak self] in self?.refresh() }; refresh()
    }
    func refresh() {
        visibilityItem.title=session?.isVisible == true ? "隐藏角色" : "显示角色"; visibilityItem.isEnabled=session != nil; recallItem.isEnabled=session != nil
        checkUpdatesItem.isEnabled=session != nil
        helpItem.isEnabled=session != nil && !terminating && settingsController?.hasBlockingSheet != true && chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil
        copyDiagnosticsItem.isEnabled=canUseSupportCommands
        diagnosticResultItem.title=diagnostics?.feedback.message ?? "";diagnosticResultItem.isHidden=diagnostics?.feedback.message==nil
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
        focusWindow?.refreshPreferences()
        chatItem.isEnabled = session != nil && !terminating && settingsController?.hasBlockingSheet != true && chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow == nil
        contextChatItem.isEnabled = chatItem.isEnabled
        quickChatItem.isEnabled = chatItem.isEnabled;contextQuickChatItem.isEnabled = chatItem.isEnabled
        if let session {
            let m=session.skin.manifest
            let context=ChatCharacter(id:m.id,name:m.name,description:m.description,skinRevision:session.skinRevision)
            if chat?.character != context { chat?.activate(context) }
        }
        refreshVoiceEnvironment()
    }
    @objc private func openChat() {
        guard session != nil, !terminating, session?.gate.exiting == false, settingsController?.hasBlockingSheet != true, chatPresentation?.hasBlockingSheet != true, NSApp.modalWindow == nil else { return }
        chatPresentation?.present(.full)
    }
    @objc func openQuickChat() {
        guard session != nil, canUseSupportCommands else { return }
        chatPresentation?.present(.quick)
    }
    func presentChatReply(_ text:String) {session?.presentChatReply(text,showBubble:chatPresentation?.isQuickVisible != true)}
    @objc private func retry() { guard canUseSupportCommands else{return};session?.retrySave(); refresh() }
    @objc private func reset() { guard canUseSupportCommands else{return};session?.resetProtectedSettings(); refresh() }
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu || menu === contextMenu || quickSkins?.menus.contains(where:{$0 === menu})==true || focusMenus?.trackingMenus.contains(where:{$0 === menu})==true else{return}
        openMenus.insert(ObjectIdentifier(menu));session?.setMenuOpen(true);refresh()
        focus?.setDisplayVisible(true,source:"menus")
        quickSkins?.reload()
    }
    func menuDidClose(_ menu: NSMenu) {
        openMenus.remove(ObjectIdentifier(menu));session?.setMenuOpen(menuOpen)
        focus?.setDisplayVisible(menuOpen,source:"menus")
        refreshVoiceEnvironment()
    }
    private func refreshVoiceEnvironment() {
        chat?.updateVoiceEnvironment(.init(surface: chatPresentation?.voiceSurface ?? .hidden,
            blocked: menuOpen || !voiceSheets.isEmpty || settingsController?.hasBlockingSheet == true || chatPresentation?.hasBlockingSheet == true || NSApp.modalWindow != nil,
            effectiveQuiet: session?.effectiveQuiet == true,
            sleeping: chat?.sleeping == true, terminating: terminating || session?.gate.exiting == true, disposed: chat?.disposed == true))
    }
    @objc nonisolated private func voiceWindowChanged(_ notification: Notification) {
        let begin = notification.name == NSWindow.willBeginSheetNotification
        let end = notification.name == NSWindow.didEndSheetNotification
        let id = (notification.object as? NSWindow).map(ObjectIdentifier.init)
        if Thread.isMainThread { MainActor.assumeIsolated { handleVoiceWindowChange(begin:begin,end:end,id:id) } }
        else { Task { @MainActor [weak self] in self?.handleVoiceWindowChange(begin:begin,end:end,id:id) } }
    }
    private func handleVoiceWindowChange(begin:Bool,end:Bool,id:ObjectIdentifier?) {
        if let id { if begin {voiceSheets.insert(id)}; if end {voiceSheets.remove(id)} }
        refreshVoiceEnvironment()
        // The first notification may precede attachedSheet/modalWindow assignment.
        DispatchQueue.main.async { [weak self] in self?.refreshVoiceEnvironment() }
    }
    @objc private func wave() {guard canUseSupportCommands else{return};session?.play(.waving)}
    @objc private func jump() {guard canUseSupportCommands else{return};session?.play(.jumping)}
    @objc private func toggle() { guard canUseSupportCommands else{return};if let session { session.setVisible(!session.isVisible) }; refresh() }
    @objc private func recall() { guard canUseSupportCommands else{return};session?.recall(); refresh() }
    @objc private func toggleQuiet() { guard canUseSupportCommands else{return};if let session {session.setQuiet(!session.isQuiet)};refresh() }
    @objc private func toggleLock() {
        guard canUseSupportCommands,let session else{return}
        var prefs=session.preferences;prefs.positionLocked.toggle();session.setPreferences(prefs);refresh()
    }
    @objc private func openSettings() {presentSettings()}
    private var canUseSupportCommands:Bool {!terminating && session?.gate.exiting != true && settingsController?.hasBlockingSheet != true && chatPresentation?.hasBlockingSheet != true && NSApp.modalWindow==nil}
    @objc private func copyDiagnostics() {diagnostics?.copyDiagnostics();refresh()}
    @objc private func openHelp() {
        guard !terminating,session?.gate.exiting==false,settingsController?.hasBlockingSheet != true,NSApp.modalWindow==nil else{return}
        presentSettings(tab:.help)
    }
    private func presentSettings(tab:SettingsTab?=nil) {
        guard canUseSupportCommands,let session,let shortcuts else { return }
        if settingsController == nil { settingsController=SettingsWindowController(session:session,updates:updates,shortcuts:shortcuts,loginItem:loginItem,model:skinModel,diagnostics:diagnostics) }
        settingsController?.present(tab:tab)
    }
    @objc private func checkUpdates() {guard session != nil,canUseSupportCommands else{return};presentSettings(tab:.about);updates.check()}
    func startShortcuts(){shortcuts?.start();focusWindow?.start()}
    func beginTermination(){guard !terminating else{return};terminating=true;chat?.beginTermination();chatPresentation?.beginTermination();focusWindow?.beginTermination();focus?.setTerminating(true);contextMenu.cancelTracking();updates.cancel();quickSkins?.cancel();if let settingsController{settingsController.beginTermination()}else{skinModel?.beginTermination()};refresh()}
    func cancelTermination(){terminating=false;chat?.cancelTermination();chatPresentation?.cancelTermination();focus?.setTerminating(false);focusWindow?.cancelTermination();if let settingsController{settingsController.cancelTermination()}else{skinModel?.cancelTermination()};refresh()}
    @objc private func quit() { guard canUseSupportCommands else{return};onQuit() }
    func dispose() { NotificationCenter.default.removeObserver(self);voiceSheets.removeAll();terminating=true;chatPresentation?.dispose();chatPresentation=nil;chatWindow=nil;quickChatWindow=nil;chat?.dispose();chat=nil;focusWindow?.dispose();focusWindow=nil;focus?.dispose();focusMenus?.dispose();focusMenus=nil;contextMenu.cancelTracking();quickSkins?.dispose();quickSkins=nil;session?.view.contextMenu=nil;contextMenu.delegate=nil;openMenus.removeAll();updates.cancel();shortcuts?.dispose();settingsController?.close(); settingsController=nil; session?.setMenuOpen(false); item.menu=nil; menu.delegate=nil; NSStatusBar.system.removeStatusItem(item) }
}
