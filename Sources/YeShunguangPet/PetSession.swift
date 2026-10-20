import AppKit
import PetCore

@MainActor final class PetSession: NSObject {
    private(set) var skin: LoadedSkin, atlas: SpriteAtlas
    let panel: PetPanel, view: PetView
    let defaultSkin: LoadedSkin, library: SkinLibrary
    private(set) var selectedSkinID: String?
    private(set) var skinWarning: String?
    let settings: SettingsStore
    let screens: () -> [ScreenArea]
    private var placement: PlacementSnapshot?
    private(set) var preferences=PetPreferences()
    private var wantsVisible=true
    private(set) var persistenceError: String?
    private(set) var protectedSettings=false
    let now: () -> Duration
    var playback: SpritePlayback
    let interaction: PetInteraction
    var gate=RuntimeGate()
    private(set) var action: PetAction = .idle
    private var frame: FrameLocation?
    private var frameUpdates=0
    private let startedAt: Duration
    private var dragOrigin=CGPoint.zero
    var onStatusChange: (() -> Void)?
    var isVisible: Bool { gate.visible }
    private var gaze=MouseGaze()
    private var nextGazeSample: Duration?
    private var gazeSamples=0
    private var menuOpen=false,settingsOpen=false
    private let pointerPosition: () -> CGPoint
    var gazeDirection: Int? { gaze.direction }
    var supportsGaze: Bool { skin.manifest.lookDirections.count==16 }
    private var canSampleGaze: Bool { gate.shouldRunFrames && preferences.lookAtMouse && supportsGaze && action == .idle && !interaction.isPointerBusy && !menuOpen && !settingsOpen }
    func setMenuOpen(_ open: Bool) {
        guard !gate.exiting,menuOpen != open else { return }; menuOpen=open; cancelInput()
    }
    func setSettingsOpen(_ open: Bool) {
        guard !gate.exiting,settingsOpen != open else { return }; settingsOpen=open; cancelInput()
    }
    lazy var scheduler=FrameScheduler(now:now) { [weak self] in self?.tick() }
    init(skin: LoadedSkin, defaultSkin: LoadedSkin? = nil, now: @escaping () -> Duration, settings: SettingsStore, screens: @escaping () -> [ScreenArea], pointerPosition: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.settings=settings; self.screens=screens; self.startedAt=now()
        self.pointerPosition=pointerPosition
        self.defaultSkin=defaultSkin ?? skin; library=SkinLibrary(directory:settings.url.deletingLastPathComponent().appendingPathComponent("Skins",isDirectory:true))
        self.skin=skin; self.now=now; atlas=SpriteAtlas(skin:skin)
        let size=CGSize(width:skin.manifest.cellWidth,height:skin.manifest.cellHeight)
        panel=PetPanel(size:size); view=PetView(frame:CGRect(origin:.zero,size:size))
        playback=SpritePlayback(now:now); interaction=PetInteraction(doubleClickInterval:.seconds(NSEvent.doubleClickInterval),now:now)
        super.init(); gate.loaded=true; panel.contentView=view
        playback.start(skin.manifest.animations[.idle]!)
        view.onDown = { [weak self] point,count in guard let self,self.gate.shouldRunFrames else { return }; self.interaction.pointerDown(at:point,clickCount:count); self.reschedule() }
        view.onMove = { [weak self] point in guard let self else { return }; self.apply(self.interaction.pointerMoved(to:point)); self.reschedule() }
        view.onUp = { [weak self] point in guard let self else { return }; self.apply(self.interaction.pointerUp(at:point)); self.reschedule() }
        NotificationCenter.default.addObserver(self,selector:#selector(screenNotification),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        let center=NSWorkspace.shared.notificationCenter
        center.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        center.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.screensDidSleepNotification,object:nil)
        center.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
        center.addObserver(self,selector:#selector(didWake),name:NSWorkspace.screensDidWakeNotification,object:nil)
    }
    func start(restoringSkin: Bool = true) {
        switch settings.load() {
        case .loaded(let saved): placement=saved.placement; preferences=saved.preferences; selectedSkinID=saved.selectedSkinID
        case .missing: break
        case .protectedFile(let message): persistenceError=message; protectedSettings=true
        }
        if restoringSkin,let id=selectedSkinID {
            do {
                skin=try library.load(id:id); atlas=SpriteAtlas(skin:skin)
                playback.start(skin.manifest.animations[.idle]!)
            } catch { selectedSkinID=nil; skinWarning="上次使用的皮肤无法读取，已恢复默认角色：\(error.localizedDescription)" }
        }
        applyWindowPreferences()
        applyPlacement(WindowPlacement.restore(placement,size:panel.frame.size,screens:screens()))
        setVisible(true)
    }
    func useImportedSkin(_ imported: ImportedSkin) throws { try switchSkin(imported.skin,id:imported.id) }
    func canDeleteImportedSkin(id: String) -> Bool {
        guard !gate.exiting,!protectedSettings,let uuid=UUID(uuidString:id) else { return false }
        if selectedSkinID.flatMap(UUID.init(uuidString:))==uuid { return false }
        return skin.directory != library.directory.appendingPathComponent(id,isDirectory:true).resolvingSymlinksInPath()
    }
    func restoreDefaultSkin() throws { try switchSkin(defaultSkin,id:nil) }
    private func switchSkin(_ next: LoadedSkin, id: String?) throws {
        guard !gate.exiting else { throw SkinError("桌宠正在退出，未切换皮肤") }
        let nextAtlas=SpriteAtlas(skin:next), animation=next.manifest.animations[.idle]!
        let first=FrameLocation(row:animation.row,column:animation.startColumn)
        let image=try nextAtlas.frame(at:first)
        cancelInput()
        let size=CGSize(width:Double(next.manifest.cellWidth)*preferences.scale,height:Double(next.manifest.cellHeight)*preferences.scale)
        let nextPlacement=WindowPlacement.capture(origin:panel.frame.origin,size:size,screens:screens()) ?? placement
        do { try settings.save(PetSettings(placement:nextPlacement,preferences:preferences,selectedSkinID:id)) }
        catch { persistenceError=error.localizedDescription; onStatusChange?(); throw error }
        // Persistence is committed before touching the current image or playback.
        scheduler.cancel(); skin=next; atlas=nextAtlas; selectedSkinID=id; skinWarning=nil; persistenceError=nil
        action = .idle; playback.start(animation); frame=first; view.image=image; frameUpdates += 1
        applyWindowPreferences(); applyPlacement(nextPlacement); synchronize(); onStatusChange?()
    }
    func setPreferences(_ value: PetPreferences) {
        guard !gate.exiting,value.isValid,value != preferences else { return }
        cancelInput()
        preferences=value; applyWindowPreferences()
        applyPlacement(WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()))
        synchronize()
        _=savePosition()
    }
    private func applyWindowPreferences() {
        let size=CGSize(width:Double(skin.manifest.cellWidth)*preferences.scale,height:Double(skin.manifest.cellHeight)*preferences.scale)
        panel.setFrame(CGRect(origin:panel.frame.origin,size:size),display:true)
        view.setFrameSize(size); view.needsDisplay=true
        panel.level=preferences.alwaysOnTop ? .floating : .normal
    }
    private func applyPlacement(_ value: PlacementSnapshot?) {
        guard let value else { return }
        placement=value; panel.setFrameOrigin(value.origin)
    }
    func recall() {
        cancelInput()
        guard let recalled=WindowPlacement.recall(size:panel.frame.size,screens:screens()) else { return }
        applyPlacement(recalled); setVisible(true); play(.waving); _=savePosition()
    }
    @objc private func screenNotification(_ notification: Notification) { screensChanged() }
    func screensChanged() {
        cancelInput()
        let restored=WindowPlacement.restore(placement,size:panel.frame.size,screens:screens())
        if restored != placement { applyPlacement(restored); if restored != nil { _=savePosition() } }
        if screens().isEmpty { gate.visible=false; panel.orderOut(nil); synchronize() }
        else if wantsVisible && !gate.visible { setVisible(true) }
    }
    @discardableResult private func savePosition() -> Bool {
        if let current=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()) { placement=current }
        do { try settings.save(PetSettings(placement:placement,preferences:preferences,selectedSkinID:selectedSkinID)); persistenceError=nil; onStatusChange?(); return true }
        catch { persistenceError=error.localizedDescription; onStatusChange?(); return false }
    }
    func retrySave() { _=savePosition() }
    func resetProtectedSettings() {
        do { try settings.backupAndReset(); protectedSettings=false; _=savePosition() }
        catch { persistenceError=error.localizedDescription; onStatusChange?() }
    }
    func requestExit() -> Bool { savePosition() }
    func play(_ requested: PetAction) {
        guard !gate.exiting else { return }
        gaze.reset(); nextGazeSample=nil
        let next=skin.manifest.resolve(requested)
        action=next; playback.start(skin.manifest.animations[next]!); render(); reschedule()
    }
    func setVisible(_ visible: Bool) {
        guard !gate.exiting else { return }
        cancelInput(); wantsVisible=visible; gate.visible=visible && !screens().isEmpty
        if gate.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        synchronize(); onStatusChange?()
    }
    func setSleeping(_ sleeping: Bool) { guard !gate.exiting else { return }; cancelInput(); gate.sleeping=sleeping; if !sleeping { screensChanged() }; synchronize() }
    @objc private func willSleep(_ notification: Notification) { setSleeping(true) }
    @objc private func didWake(_ notification: Notification) { setSleeping(false) }
    func cancelInput() {
        let wasLooking=gaze.direction != nil
        gaze.reset(); nextGazeSample=nil
        if wasLooking && gate.shouldRunFrames { playback.resume(); render() }
        if interaction.cancel() { finishDrag(); play(.idle) }
        reschedule()
    }
    private func synchronize() {
        if gate.shouldRunFrames { playback.resume(); render() } else { playback.pause() }
        reschedule()
    }
    private func apply(_ effects: [InteractionEffect]) {
        for effect in effects {
            switch effect {
            case .beginDrag: dragOrigin=panel.frame.origin
            case .drag(let delta):
                let target=CGPoint(x:dragOrigin.x+delta.width,y:dragOrigin.y+delta.height)
                let dx=target.x-panel.frame.minX; panel.setFrameOrigin(target)
                let requested: PetAction=dx>0 ? .runningRight : dx<0 ? .runningLeft : .idle
                let resolved=skin.manifest.resolve(requested)
                if resolved != action { play(resolved) }
            case .finishDrag: finishDrag(); play(.idle)
            case .play(let requested): play(requested)
            }
        }
    }
    func finishDrag() {
        applyPlacement(WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()))
        _=savePosition()
    }
    private func render() {
        var sample=playback.sample()
        if sample.completed { action = .idle; playback.start(skin.manifest.animations[.idle]!); sample=playback.sample() }
        let animation=skin.manifest.animations[action]!
        let location=gaze.direction.map { skin.manifest.lookDirections[$0] } ?? FrameLocation(row:animation.row,column:animation.startColumn+sample.index)
        if location != frame {
            do { view.image=try atlas.frame(at:location); frame=location; frameUpdates += 1 }
            catch { setVisible(false) }
        }
    }
    func tick() {
        guard gate.shouldRunFrames else { return }
        apply(interaction.expireClick()); render()
        if updateGaze(allowSample:true) { render() }
        reschedule()
    }
    @discardableResult private func updateGaze(allowSample: Bool) -> Bool {
        let previous=gaze.direction
        if !canSampleGaze {
            gaze.reset(); nextGazeSample=nil
            if previous != nil && gate.shouldRunFrames { playback.resume() }
        } else {
            let current=now()
            if nextGazeSample==nil { nextGazeSample=current + .milliseconds(100) }
            if allowSample,let deadline=nextGazeSample,current>=deadline {
                gazeSamples += 1
                _=gaze.sample(pointer:pointerPosition(),bounds:panel.frame,at:current)
                nextGazeSample=current + .milliseconds(100)
                if gaze.direction != nil { playback.pause() }
                else if previous != nil { playback.resume() }
            }
        }
        return previous != gaze.direction
    }
    func reschedule() {
        guard gate.shouldRunFrames else { gaze.reset(); nextGazeSample=nil; scheduler.cancel(); return }
        if updateGaze(allowSample:false) { render() }
        var delay=gaze.direction==nil ? playback.sample().untilNextFrame : nil
        if let deadline=interaction.nextClickDeadline { let click=max(.zero,deadline-now()); delay=delay.map{min($0,click)} ?? click }
        if let deadline=nextGazeSample { let look=max(.zero,deadline-now()); delay=delay.map{min($0,look)} ?? look }
        scheduler.schedule(after:delay)
    }
    func exportMetrics(to url: URL) throws {
        let duration=now()-startedAt
        let seconds=Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18
        var data: [String:Any] = ["schemaVersion":1,"durationSeconds":seconds,"schedulerWakes":scheduler.wakeCount,"frameUpdates":frameUpdates,"visible":gate.visible,"action":action.rawValue,"skinID":skin.manifest.id,"window":["width":panel.frame.width,"height":panel.frame.height],"displays":screens().map { ["width":$0.visibleFrame.width,"height":$0.visibleFrame.height] },"backingScale":panel.backingScaleFactor,"lookAtMouseEnabled":preferences.lookAtMouse,"gazeSamples":gazeSamples]
        if let direction=gaze.direction { data["gazeDirection"]=direction }
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    func prepareToExit() {
        guard !gate.exiting else { return }
        gate.exiting=true; gaze.reset(); nextGazeSample=nil; interaction.cancel(); playback.pause(); scheduler.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        view.onDown=nil; view.onMove=nil; view.onUp=nil
        panel.orderOut(nil); panel.close()
    }
}
