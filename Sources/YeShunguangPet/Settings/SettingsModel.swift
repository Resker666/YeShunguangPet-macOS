import AppKit
import SwiftUI
import PetCore

@MainActor final class SettingsModel: ObservableObject {
    @Published var selectedTab:SettingsTab = .skin {didSet{if oldValue != selectedTab{resetShortcutEdits()}}}
    @Published private(set) var shortcutEditGeneration=0
    func resetShortcutEdits(){shortcutEditGeneration+=1}
    let loginItem:LoginItemController
    @Published private(set) var preferences: PetPreferences
    @Published private(set) var saveError: String?
    @Published private(set) var candidate: SkinPackage?
    @Published private(set) var skinError: String? {didSet{onSkinStateChange?()}}
    @Published private(set) var isBusy=false {didSet{onSkinStateChange?()}}
    @Published private(set) var skinName: String
    @Published private(set) var currentImage: CGImage?
    @Published private(set) var candidateImage: CGImage?
    @Published private(set) var skinWarning: String?
    @Published private(set) var libraryEntries=[SkinLibraryEntry]() {didSet{onSkinStateChange?()}}
    @Published private(set) var libraryError: String? {didSet{onSkinStateChange?()}}
    @Published private(set) var isTerminating=false {didSet{onSkinStateChange?()}}
    var onSkinStateChange:(()->Void)?
    @Published private(set) var gazeAvailable=false
    @Published private(set) var roamingAvailable=false
    @Published var isDropTargeted=false
    private(set) var hasPendingMutation=false
    private(set) var terminationCleanupError: String?
    private let previewPackage:@Sendable (URL)throws->SkinPackage
    private let installPackage: @Sendable (SkinLibrary,SkinPackage) throws -> ImportedSkin
    private let loadSkin:@Sendable (SkinLibrary,String)throws->LoadedSkin
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
    func useSkin(id: String,cancelWithPreview:Bool=true) async {
        guard let session,!session.gate.exiting,!isTerminating,!isBusy else { return }
        cancelSkinSelection()
        let generation=selectionGeneration,library=session.library,loadSkin=loadSkin
        isBusy=true; hasPendingMutation=true
        defer { finishMutation() }
        do {
            let skin=try await Task.detached(priority:.userInitiated) { try loadSkin(library,id) }.value
            if (!cancelWithPreview || generation==selectionGeneration),!Task.isCancelled,!isTerminating,!session.gate.exiting {
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
        let generation=selectionGeneration,previewPackage=previewPackage
        candidate=nil; candidateImage=nil; skinError=nil; isBusy=true; hasPendingMutation=true
        defer { finishMutation() }
        do {
            let package=try await Task.detached(priority:.userInitiated) {
                try previewPackage(url)
            }.value
            guard generation==selectionGeneration,!Task.isCancelled,!session.gate.exiting else { return }
            let idle=package.skin.manifest.animations[.idle]!
            candidateImage=try SpriteAtlas(skin:package.skin).frame(at:.init(row:idle.row,column:idle.startColumn))
            candidate=package
        } catch {
            if error is SkinImportCleanupError {terminationCleanupError=error.localizedDescription}
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
    func reportSkinDropError(_ message:String) { skinError=message }
    func restoreDefaultSkin() {
        guard let session,!isTerminating,!isBusy else { return }
        do { try session.restoreDefaultSkin(); cancelSkinSelection(); refresh() }
        catch { skinError=error.localizedDescription; refresh() }
    }
    private weak var session: PetSession?
    init(session: PetSession,loginItem:LoginItemController?=nil,previewPackage:@escaping @Sendable (URL)throws->SkinPackage={url in
        let isDirectory=try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true
        guard isDirectory || ["zip","json"].contains(url.pathExtension.lowercased()) else {
            throw NSError(domain:"SkinDrop",code:1,userInfo:[NSLocalizedDescriptionKey:"请选择一套皮肤的 ZIP、皮肤文件夹或 pet.json。"])
        }
        return try SkinLoader.readPackage(manifestURL:isDirectory ? url.appendingPathComponent("pet.json") : url)
    },installPackage: @escaping @Sendable (SkinLibrary,SkinPackage) throws -> ImportedSkin = { try $0.install($1) },loadSkin:@escaping @Sendable (SkinLibrary,String)throws->LoadedSkin = {try $0.load(id:$1)}) {
        self.loginItem=loginItem ?? LoginItemController()
        self.installPackage=installPackage
        self.loadSkin=loadSkin
        self.previewPackage=previewPackage
        self.session=session; preferences=session.preferences; saveError=session.persistenceError; skinName=session.skin.manifest.name
        refresh()
    }
    func refresh() {
        guard let session else { return }
        loginItem.refresh()
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
    func setSnapToEdges(_ enabled:Bool) {
        guard !isTerminating else{return}
        var value=preferences;value.snapToEdges=enabled;session?.setPreferences(value);refresh()
    }
    func setPositionLocked(_ enabled:Bool) {
        guard !isTerminating else{return}
        var value=preferences;value.positionLocked=enabled;session?.setPreferences(value);refresh()
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
