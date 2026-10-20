import AppKit
import SwiftUI
import PetCore
import UniformTypeIdentifiers

@MainActor final class SettingsModel: ObservableObject {
    @Published private(set) var preferences: PetPreferences
    @Published private(set) var saveError: String?
    @Published private(set) var candidate: SkinPackage?
    @Published private(set) var skinError: String?
    @Published private(set) var isBusy=false
    @Published private(set) var skinName: String
    @Published private(set) var currentImage: CGImage?
    @Published private(set) var candidateImage: CGImage?
    @Published private(set) var skinWarning: String?
    private var selectionGeneration=0
    func previewSkin(at url: URL) async {
        guard let session,!session.gate.exiting,!isBusy else { return }
        session.cancelInput(); selectionGeneration += 1
        let generation=selectionGeneration
        candidate=nil; candidateImage=nil; skinError=nil; isBusy=true
        defer { isBusy=false }
        do {
            let package=try await Task.detached(priority:.userInitiated) {
                let isDirectory=try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true
                return try SkinLoader.readPackage(manifestURL:isDirectory ? url.appendingPathComponent("pet.json") : url)
            }.value
            guard generation==selectionGeneration,!Task.isCancelled,!session.gate.exiting else { return }
            let idle=package.skin.manifest.animations[.idle]!
            candidateImage=try SpriteAtlas(skin:package.skin).frame(at:.init(row:idle.row,column:idle.startColumn))
            candidate=package
        } catch {
            if generation==selectionGeneration,!Task.isCancelled { skinError=error.localizedDescription }
        }
    }
    func confirmImport() async {
        guard let session,let package=candidate,!isBusy,!session.gate.exiting else { return }
        guard !session.protectedSettings else { skinError="原配置受保护，请先从菜单栏备份并重置，再导入。"; return }
        let generation=selectionGeneration, library=session.library
        var installed: ImportedSkin?
        isBusy=true; skinError=nil
        defer { isBusy=false; refresh() }
        do {
            let imported=try await Task.detached(priority:.userInitiated) { try library.install(package) }.value
            installed=imported
            guard generation==selectionGeneration,!Task.isCancelled,!session.gate.exiting else {
                try await Task.detached { try library.discardNewImport(id:imported.id) }.value
                installed=nil; return
            }
            try session.useImportedSkin(imported)
            installed=nil; candidate=nil; candidateImage=nil
        } catch {
            var message=error.localizedDescription
            if let imported=installed {
                do { try await Task.detached { try library.discardNewImport(id:imported.id) }.value }
                catch { message += "；未能清理这次未使用的副本：\(error.localizedDescription)" }
            }
            if generation==selectionGeneration,!Task.isCancelled { skinError=message }
        }
    }
    func cancelSkinSelection() { selectionGeneration += 1; candidate=nil; candidateImage=nil; skinError=nil }
    func restoreDefaultSkin() {
        guard let session,!isBusy else { return }
        do { try session.restoreDefaultSkin(); cancelSkinSelection(); refresh() }
        catch { skinError=error.localizedDescription; refresh() }
    }
    private weak var session: PetSession?
    init(session: PetSession) {
        self.session=session; preferences=session.preferences; saveError=session.persistenceError; skinName=session.skin.manifest.name
        refresh()
    }
    func refresh() {
        guard let session else { return }
        preferences=session.preferences; saveError=session.persistenceError
        skinName=session.skin.manifest.name; skinWarning=session.skinWarning
        let idle=session.skin.manifest.animations[.idle]!
        currentImage=try? session.atlas.frame(at:.init(row:idle.row,column:idle.startColumn))
    }
    func setScale(_ scale: Double) {
        var value=preferences; value.scale=scale; session?.setPreferences(value); refresh()
    }
    func setAlwaysOnTop(_ enabled: Bool) {
        var value=preferences; value.alwaysOnTop=enabled; session?.setPreferences(value); refresh()
    }
}

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private weak var session: PetSession?
    private var filePanel: NSOpenPanel?
    init(session: PetSession) {
        self.session=session; model=SettingsModel(session:session)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:460,height:560),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="叶瞬光桌宠设置"; window.isReleasedWhenClosed=false
        super.init(window:window)
        window.contentViewController=NSHostingController(rootView:PetSettingsView(model:model,onChooseSkin:{ [weak self] in self?.chooseSkin() }))
        window.delegate=self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        session?.cancelInput(); model.refresh()
        showWindow(nil); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    private func chooseSkin() {
        guard let window,!model.isBusy,filePanel==nil else { return }
        let panel=NSOpenPanel()
        panel.title="选择皮肤"; panel.message="选择皮肤文件夹或其中的 pet.json；对应 PNG 需放在同一文件夹。"
        panel.prompt="预览"; panel.canChooseFiles=true; panel.canChooseDirectories=true
        panel.allowsMultipleSelection=false; panel.allowedContentTypes=[.json]
        filePanel=panel
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }
            self.filePanel=nil
            guard response == .OK,let selected=panel.url else { return }
            Task { [weak self] in
                let scoped=selected.startAccessingSecurityScopedResource()
                defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
                await self?.model.previewSkin(at:selected)
            }
        }
    }
    func windowWillClose(_ notification: Notification) { filePanel?.cancel(nil); model.cancelSkinSelection() }
}

private struct PetSettingsView: View {
    @ObservedObject var model: SettingsModel
    let onChooseSkin: () -> Void
    private var version: String {
        let info=Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "开发版")（\(info["CFBundleVersion"] as? String ?? "—")）"
    }
    private var architecture: String {
        #if arch(arm64)
        "Apple Silicon · arm64"
        #else
        "Intel · x86_64（实验版）"
        #endif
    }
    var body: some View {
        Form {
            Section("皮肤") {
                HStack(spacing:16) {
                    if let image=model.currentImage {
                        Image(decorative:image,scale:1).resizable().interpolation(.high).scaledToFit().frame(width:72,height:80)
                    }
                    Text(model.skinName).font(.headline)
                }
                HStack {
                    Button("选择皮肤…",action:onChooseSkin)
                    Button("恢复默认皮肤") { model.restoreDefaultSkin() }
                }.disabled(model.isBusy)
                if let package=model.candidate {
                    HStack(spacing:16) {
                        if let image=model.candidateImage {
                            Image(decorative:image,scale:1).resizable().interpolation(.high).scaledToFit().frame(width:72,height:80)
                        }
                        VStack(alignment:.leading,spacing:6) {
                            Text("待导入：\(package.skin.manifest.name)")
                            Text("\(package.skin.manifest.cellWidth) × \(package.skin.manifest.cellHeight) 点（100%）").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("导入并使用") { Task { await model.confirmImport() } }.buttonStyle(.borderedProminent)
                                Button("取消") { model.cancelSkinSelection() }
                            }.disabled(model.isBusy)
                        }
                    }
                }
                if model.isBusy { HStack { ProgressView().controlSize(.small); Text("正在处理皮肤…") } }
                if let error=model.skinError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let warning=model.skinWarning { Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("导入会保存素材副本，原文件保持不变。预览为待机首帧。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            if let error=model.saveError {
                Section {
                    Text("设置尚未保存").font(.headline)
                    Text(error).font(.caption).textSelection(.enabled)
                    Text("请从菜单栏重试保存；原配置受保护时，先选择“备份原配置并重置”。")
                        .font(.caption)
                }
            }
            Section {
                LabeledContent("版本",value:version)
                LabeledContent("架构",value:architecture)
            }
        }
        .formStyle(.grouped)
        .frame(width:460,height:560)
    }
}
