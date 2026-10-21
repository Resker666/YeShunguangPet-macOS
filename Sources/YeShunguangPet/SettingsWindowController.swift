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
    @Published private(set) var libraryEntries=[SkinLibraryEntry]()
    @Published private(set) var libraryError: String?
    @Published private(set) var isTerminating=false
    @Published private(set) var gazeAvailable=false
    @Published private(set) var roamingAvailable=false
    private(set) var hasPendingMutation=false
    private(set) var terminationCleanupError: String?
    private let installPackage: @Sendable (SkinLibrary,SkinPackage) throws -> ImportedSkin
    private var mutationWaiters=[CheckedContinuation<Void,Never>]()
    func beginTermination() {
        isTerminating=true; cancelSkinSelection()
    }
    func cancelTermination() { isTerminating=false }
    func waitForPendingMutations() async {
        guard hasPendingMutation else { return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func finishMutation() {
        guard hasPendingMutation else { return }
        hasPendingMutation=false; isBusy=false; refresh()
        let waiters=mutationWaiters; mutationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func reloadLibrary() async {
        guard let session,!session.gate.exiting,!isTerminating,!isBusy else { return }
        let generation=selectionGeneration,library=session.library
        isBusy=true; libraryError=nil
        defer { isBusy=false }
        do {
            let entries=try await Task.detached(priority:.userInitiated) { try library.entries() }.value
            guard generation==selectionGeneration,!Task.isCancelled,!session.gate.exiting else { return }
            libraryEntries=entries
        } catch { if generation==selectionGeneration { libraryError=error.localizedDescription } }
    }
    func useSkin(id: String) async {
        guard let session,!session.gate.exiting,!isTerminating,!isBusy else { return }
        cancelSkinSelection()
        let generation=selectionGeneration,library=session.library
        isBusy=true; hasPendingMutation=true
        defer { finishMutation() }
        do {
            let skin=try await Task.detached(priority:.userInitiated) { try library.load(id:id) }.value
            if generation==selectionGeneration,!Task.isCancelled,!session.gate.exiting {
                try session.useImportedSkin(ImportedSkin(id:id,skin:skin))
            }
        } catch { skinError=error.localizedDescription }
        finishMutation(); await reloadLibrary()
    }
    // Called after the settings view's destructive-action confirmation.
    func deleteSkin(id: String) async {
        guard let session,!session.gate.exiting,!isTerminating,!isBusy else { return }
        guard session.canDeleteImportedSkin(id:id) else { skinError="此皮肤正在使用、仍被配置记住，或原配置受保护；请先切换或重置配置。"; return }
        cancelSkinSelection(); isBusy=true; hasPendingMutation=true
        defer { finishMutation() }
        let library=session.library
        do { try await Task.detached(priority:.userInitiated) { try library.remove(id:id) }.value }
        catch { skinError=error.localizedDescription; if isTerminating { terminationCleanupError=error.localizedDescription } }
        finishMutation(); await reloadLibrary()
    }
    func isCurrentSkin(id: String) -> Bool {
        guard let session,UUID(uuidString:id) != nil else { return false }
        return session.skin.directory==session.library.directory.appendingPathComponent(id,isDirectory:true).resolvingSymlinksInPath()
    }
    func canDeleteSkin(id: String) -> Bool { !isBusy && !isTerminating && session?.canDeleteImportedSkin(id:id)==true }
    private var selectionGeneration=0
    func previewSkin(at url: URL) async {
        guard let session,!session.gate.exiting,!isTerminating,!isBusy else { return }
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
        guard let session,let package=candidate,!isBusy,!isTerminating,!session.gate.exiting else { return }
        guard !session.protectedSettings else { skinError="原配置受保护，请先从菜单栏备份并重置，再导入。"; return }
        let generation=selectionGeneration, library=session.library,installPackage=installPackage
        var installed: ImportedSkin?
        isBusy=true; skinError=nil; hasPendingMutation=true
        defer { finishMutation() }
        do {
            let imported=try await Task.detached(priority:.userInitiated) { try installPackage(library,package) }.value
            installed=imported
            guard generation==selectionGeneration,!Task.isCancelled,!session.gate.exiting else {
                try await Task.detached { try library.discardNewImport(id:imported.id) }.value
                installed=nil; return
            }
            try session.useImportedSkin(imported)
            installed=nil; candidate=nil; candidateImage=nil
        } catch {
            var message=error.localizedDescription
            if error is SkinImportCleanupError { terminationCleanupError=message }
            if let imported=installed {
                do { try await Task.detached { try library.discardNewImport(id:imported.id) }.value }
                catch {
                    message += "；未能清理这次未使用的副本：\(error.localizedDescription)"
                    terminationCleanupError=error.localizedDescription
                }
            }
            if generation==selectionGeneration,!Task.isCancelled { skinError=message }
        }
        finishMutation(); await reloadLibrary()
    }
    func cancelSkinSelection() { selectionGeneration += 1; candidate=nil; candidateImage=nil; skinError=nil }
    func restoreDefaultSkin() {
        guard let session,!isTerminating,!isBusy else { return }
        do { try session.restoreDefaultSkin(); cancelSkinSelection(); refresh() }
        catch { skinError=error.localizedDescription; refresh() }
    }
    private weak var session: PetSession?
    init(session: PetSession,installPackage: @escaping @Sendable (SkinLibrary,SkinPackage) throws -> ImportedSkin = { try $0.install($1) }) {
        self.installPackage=installPackage
        self.session=session; preferences=session.preferences; saveError=session.persistenceError; skinName=session.skin.manifest.name
        refresh()
    }
    func refresh() {
        guard let session else { return }
        preferences=session.preferences; saveError=session.persistenceError
        skinName=session.skin.manifest.name; skinWarning=session.skinWarning
        gazeAvailable=session.supportsGaze
        roamingAvailable=session.supportsRoaming
        let idle=session.skin.manifest.animations[.idle]!
        currentImage=try? session.atlas.frame(at:.init(row:idle.row,column:idle.startColumn))
    }
    func setScale(_ scale: Double) {
        guard !isTerminating else { return }
        var value=preferences; value.scale=scale; session?.setPreferences(value); refresh()
    }
    func setAlwaysOnTop(_ enabled: Bool) {
        guard !isTerminating else { return }
        var value=preferences; value.alwaysOnTop=enabled; session?.setPreferences(value); refresh()
    }
    func setLookAtMouse(_ enabled: Bool) {
        guard !isTerminating else { return }
        var value=preferences; value.lookAtMouse=enabled; session?.setPreferences(value); refresh()
    }
    func setAutomaticActions(_ enabled: Bool) {
        guard !isTerminating else { return }
        var value=preferences; value.automaticActions=enabled; session?.setPreferences(value); refresh()
    }
    func setAutomaticActionInterval(_ seconds: Int) {
        guard !isTerminating else { return }
        var value=preferences; value.automaticActionIntervalSeconds=seconds; session?.setPreferences(value); refresh()
    }
    func setDesktopRoaming(_ enabled: Bool) {
        guard !isTerminating else { return }
        var value=preferences;value.desktopRoaming=enabled;session?.setPreferences(value);refresh()
    }
    func setRoamInterval(_ seconds: Int) {
        guard !isTerminating else { return }
        var value=preferences;value.roamIntervalSeconds=seconds;session?.setPreferences(value);refresh()
    }
    func setSpeechEnabled(_ enabled:Bool) {
        guard !isTerminating else{return}
        var value=preferences;value.speechEnabled=enabled;session?.setPreferences(value);refresh()
    }
}

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private weak var session: PetSession?
    private var filePanel: NSOpenPanel?
    init(session: PetSession) {
        self.session=session; model=SettingsModel(session:session)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:520,height:640),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="叶瞬光桌宠设置"; window.isReleasedWhenClosed=false
        super.init(window:window)
        window.contentViewController=NSHostingController(rootView:PetSettingsView(model:model,onChooseSkin:{ [weak self] in self?.chooseSkin() }))
        window.delegate=self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        session?.cancelInput(); session?.setSettingsOpen(true); model.refresh()
        showWindow(nil); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        Task { [model] in await model.reloadLibrary() }
    }
    private func chooseSkin() {
        guard let window,!model.isTerminating,!model.isBusy,filePanel==nil else { return }
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
    func windowWillClose(_ notification: Notification) { filePanel?.cancel(nil); model.cancelSkinSelection(); session?.setSettingsOpen(false) }
    func beginTermination() { filePanel?.cancel(nil); model.beginTermination() }
}

private struct PetSettingsView: View {
    @ObservedObject var model: SettingsModel
    let onChooseSkin: () -> Void
    @State private var skinToDelete: SkinLibraryEntry?
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
            Section("已导入皮肤") {
                if model.libraryEntries.isEmpty { Text("导入后会显示在这里，可直接切换。").foregroundStyle(.secondary) }
                ForEach(model.libraryEntries) { entry in
                    HStack(spacing:12) {
                        if let image=entry.thumbnail {
                            Image(decorative:image,scale:1).resizable().scaledToFit().frame(width:52,height:56)
                        } else {
                            Image(systemName:"exclamationmark.triangle").frame(width:52,height:56).foregroundStyle(.secondary)
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text(entry.name)
                            if model.isCurrentSkin(id:entry.id) { Text("使用中").font(.caption).foregroundStyle(.secondary) }
                            if let error=entry.loadError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error) }
                        }
                        Spacer(minLength:4)
                        Button("使用") { Task { await model.useSkin(id:entry.id) } }
                            .disabled(model.isBusy || entry.loadError != nil || model.isCurrentSkin(id:entry.id))
                        Button { skinToDelete=entry } label: { Image(systemName:"trash") }
                            .accessibilityLabel("删除\(entry.name)")
                            .disabled(!model.canDeleteSkin(id:entry.id))
                    }
                }
                if let error=model.libraryError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Button("刷新皮肤列表") { Task { await model.reloadLibrary() } }.disabled(model.isBusy)
            }
            Section {
                LabeledContent("角色大小",value:"\(Int((model.preferences.scale*100).rounded()))%")
                Slider(value:Binding(get:{model.preferences.scale},set:{model.setScale($0)}),in:0.5...2,step:0.05) {
                    Text("角色大小")
                } minimumValueLabel: { Text("50%") } maximumValueLabel: { Text("200%") }
                .accessibilityIdentifier("pet-scale")
                Toggle("保持置顶",isOn:Binding(get:{model.preferences.alwaysOnTop},set:{model.setAlwaysOnTop($0)}))
                    .accessibilityIdentifier("pet-always-on-top")
                Toggle("注视鼠标",isOn:Binding(get:{model.preferences.lookAtMouse},set:{model.setLookAtMouse($0)}))
                    .accessibilityIdentifier("pet-look-at-mouse")
                Text(model.gazeAvailable ? "关闭设置窗口后，鼠标靠近时会短暂注视。菜单、点击和拖动期间暂停。" : "此皮肤未提供注视帧；偏好会保留，切换到支持的皮肤后生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("修改立即生效并自动保存。关闭置顶后，角色可能被其他窗口遮挡，可从菜单栏召回。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("互动台词") {
                Toggle("显示互动台词",isOn:Binding(get:{model.preferences.speechEnabled},set:{model.setSpeechEnabled($0)}))
                    .accessibilityIdentifier("pet-speech-enabled")
                Text("默认关闭。单击或拖动结束时回应，约6秒后收起，至少间隔30秒。优先使用皮肤台词；未提供时使用默认文案。安静模式下暂停显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        .disabled(model.isTerminating)
        .frame(width:520,height:640)
        .alert(item:$skinToDelete) { entry in
            Alert(title:Text("删除皮肤？"),message:Text("将删除“\(entry.name)”的已导入副本，原始文件不受影响。"),primaryButton:.destructive(Text("删除")) {
                Task { await model.deleteSkin(id:entry.id) }
            },secondaryButton:.cancel(Text("取消")))
        }
    }
}
