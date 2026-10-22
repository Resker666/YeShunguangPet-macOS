import AppKit
import SwiftUI
import PetCore
import UniformTypeIdentifiers

@MainActor private enum SkinDropSource {
    static func url(from pasteboard:NSPasteboard) -> URL? {
        guard pasteboard.pasteboardItems?.count==1,
              let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [NSURL],
              urls.count==1,let url=urls.first,url.isFileURL else { return nil }
        return url as URL
    }
}

@MainActor private final class SkinDropHostingView: NSHostingView<AnyView> {
    var canAccept:()->Bool={false}
    var onDrop:(NSPasteboard)->Bool={_ in false}
    var onTargetChanged:(Bool)->Void={_ in}
    required init(rootView:AnyView) {
        super.init(rootView:rootView)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draggingEntered(_ sender:any NSDraggingInfo) -> NSDragOperation { operation(for:sender) }
    override func draggingUpdated(_ sender:any NSDraggingInfo) -> NSDragOperation { operation(for:sender) }
    private func operation(for sender:any NSDraggingInfo) -> NSDragOperation {
        let accepted=canAccept() && sender.draggingSourceOperationMask.contains(.copy) && SkinDropSource.url(from:sender.draggingPasteboard) != nil
        onTargetChanged(accepted)
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender:(any NSDraggingInfo)?) { onTargetChanged(false) }
    override func draggingEnded(_ sender:any NSDraggingInfo) { onTargetChanged(false) }
    override func prepareForDragOperation(_ sender:any NSDraggingInfo) -> Bool { operation(for:sender) == .copy }
    override func performDragOperation(_ sender:any NSDraggingInfo) -> Bool {
        defer { onTargetChanged(false) }
        guard operation(for:sender) == .copy else { return false }
        return onDrop(sender.draggingPasteboard)
    }
}

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    let updates:ReleaseUpdateModel
    let shortcuts:ShortcutController
    let diagnostics:SupportDiagnosticsModel
    var hasBlockingSheet:Bool {filePanel != nil || window?.attachedSheet != nil || NSApp.modalWindow != nil}
    private weak var session: PetSession?
    private var filePanel: NSOpenPanel? {didSet{session?.onStatusChange?()}}
    private var previewTask:Task<Void,Never>?
    init(session: PetSession,updates:ReleaseUpdateModel,shortcuts:ShortcutController,loginItem:LoginItemController?=nil,model:SettingsModel?=nil,diagnostics:SupportDiagnosticsModel?=nil) {
        self.updates=updates;self.shortcuts=shortcuts
        self.session=session; self.model=model ?? SettingsModel(session:session,loginItem:loginItem)
        let settingsModel=self.model
        self.diagnostics=diagnostics ?? SupportDiagnosticsModel(capture:{[weak session] in SupportDiagnosticSnapshot.capture(session:session,focusWindow:nil)},canCopy:{[weak session,weak settingsModel] in session?.gate.exiting==false && settingsModel?.isTerminating==false && NSApp.modalWindow==nil})
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:520,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.minSize=CGSize(width:520,height:480); window.title="叶瞬光桌宠设置"; window.isReleasedWhenClosed=false
        super.init(window:window)
        self.model.onSettingsPresentationChange={[weak self] in self?.updateFocusVisibility()}
        for name in [NSApplication.didHideNotification,NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self,selector:#selector(appVisibilityChanged),name:name,object:nil)
        }
        let view=SkinDropHostingView(rootView:AnyView(SettingsTabsView(model:self.model,updates:updates,shortcuts:shortcuts,login:self.model.loginItem,diagnostics:self.diagnostics,onChooseSkin:{ [weak self] in self?.chooseSkin() })))
        view.canAccept={ [weak self] in self?.canAcceptSkinDrop==true }
        view.onDrop={ [weak self] board in self?.acceptSkinDrop(from:board) != nil }
        view.onTargetChanged={ [weak self] targeted in self?.model.isDropTargeted=targeted }
        window.contentView=view
        window.delegate=self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present(tab:SettingsTab?=nil) {
        if let tab{model.selectedTab=tab}
        session?.cancelInput(); session?.setSettingsOpen(true); model.refresh()
        showWindow(nil); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        updateFocusVisibility()
        Task { [weak self] in
            guard let self,self.previewTask==nil,self.canPreviewSkin else { return }
            await self.model.reloadLibrary()
        }
    }
    private var canPreviewSkin:Bool {
        window?.isVisible==true && !model.isTerminating && !model.isBusy && session?.gate.exiting==false
    }
    private var canAcceptSkinDrop:Bool { canPreviewSkin && previewTask==nil && filePanel==nil && window?.attachedSheet==nil }
    func acceptSkinDrop(from pasteboard:NSPasteboard) -> Task<Void,Never>? {
        guard canAcceptSkinDrop else { return nil }
        guard let url=SkinDropSource.url(from:pasteboard) else {
            model.reportSkinDropError("一次请拖入一个本地 ZIP、皮肤文件夹或 pet.json。"); return nil
        }
        return startSkinPreview(at:url)
    }
    private func startSkinPreview(at selected:URL) -> Task<Void,Never>? {
        guard canPreviewSkin,previewTask==nil else { return nil }
        model.selectedTab = .skin
        let task=Task { [weak self] in
            guard let self else { return }
            defer { self.previewTask=nil }
            guard !Task.isCancelled,self.canPreviewSkin else { return }
            let scoped=selected.startAccessingSecurityScopedResource()
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
            await self.model.previewSkin(at:selected)
            if !Task.isCancelled,self.window?.isVisible==true { await self.model.reloadLibrary() }
        }
        previewTask=task; return task
    }
    private func chooseSkin() {
        guard let window,canAcceptSkinDrop else { return }
        let panel=NSOpenPanel()
        panel.title="选择皮肤"; panel.message="选择包含一套皮肤的 ZIP、皮肤文件夹或其中的 pet.json。"
        panel.prompt="预览"; panel.canChooseFiles=true; panel.canChooseDirectories=true
        panel.allowsMultipleSelection=false; panel.allowedContentTypes=[.json,.zip]
        filePanel=panel
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }
            self.filePanel=nil
            guard response == .OK,let selected=panel.url else { return }
            _=self.startSkinPreview(at:selected)
        }
    }
    private func updateFocusVisibility(){model.focus.setDisplayVisible(window?.isVisible==true && window?.isMiniaturized==false && model.selectedTab == .focus && !NSApp.isHidden,source:"settings")}
    @objc private func appVisibilityChanged(_ notification:Notification){updateFocusVisibility()}
    func windowDidMiniaturize(_ notification:Notification){updateFocusVisibility()}
    func windowDidDeminiaturize(_ notification:Notification){updateFocusVisibility()}
    func windowDidEndSheet(_ notification:Notification){session?.onStatusChange?()}
    func windowWillClose(_ notification: Notification) {model.focus.setDisplayVisible(false,source:"settings");updates.cancel();model.resetShortcutEdits();model.resetSpeechEdits(); previewTask?.cancel(); filePanel?.cancel(nil); model.isDropTargeted=false; model.cancelSkinSelection(); session?.setSettingsOpen(false) }
    func beginTermination() {model.focus.setDisplayVisible(false,source:"settings");updates.cancel();model.resetShortcutEdits();model.resetSpeechEdits();previewTask?.cancel(); filePanel?.cancel(nil); model.isDropTargeted=false; model.beginTermination() }
    func cancelTermination(){model.cancelTermination();updateFocusVisibility()}
}
