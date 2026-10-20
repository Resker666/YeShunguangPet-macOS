import AppKit
import PetCore

@MainActor final class PetSession: NSObject {
    let skin: LoadedSkin, atlas: SpriteAtlas, panel: PetPanel, view: PetView
    let settings: SettingsStore
    let screens: () -> [ScreenArea]
    private var placement: PlacementSnapshot?
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
    lazy var scheduler=FrameScheduler(now:now) { [weak self] in self?.tick() }
    init(skin: LoadedSkin, now: @escaping () -> Duration, settings: SettingsStore, screens: @escaping () -> [ScreenArea]) {
        self.settings=settings; self.screens=screens; self.startedAt=now()
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
    func start() {
        switch settings.load() {
        case .loaded(let saved): placement=saved
        case .missing: break
        case .protectedFile(let message): persistenceError=message; protectedSettings=true
        }
        applyPlacement(WindowPlacement.restore(placement,size:panel.frame.size,screens:screens()))
        setVisible(true)
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
        guard let current=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()) else { return true }
        placement=current
        do { try settings.save(current); persistenceError=nil; onStatusChange?(); return true }
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
    func cancelInput() { interaction.cancel(); reschedule() }
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
        let location=FrameLocation(row:animation.row,column:animation.startColumn+sample.index)
        if location != frame {
            do { view.image=try atlas.frame(at:location); frame=location; frameUpdates += 1 }
            catch { setVisible(false) }
        }
    }
    private func tick() {
        guard gate.shouldRunFrames else { return }
        apply(interaction.expireClick()); render(); reschedule()
    }
    func reschedule() {
        guard gate.shouldRunFrames else { scheduler.cancel(); return }
        var delay=playback.sample().untilNextFrame
        if let deadline=interaction.nextClickDeadline { let click=max(.zero,deadline-now()); delay=delay.map{min($0,click)} ?? click }
        scheduler.schedule(after:delay)
    }
    func exportMetrics(to url: URL) throws {
        let duration=now()-startedAt
        let seconds=Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18
        let data: [String:Any] = ["schemaVersion":1,"durationSeconds":seconds,"schedulerWakes":scheduler.wakeCount,"frameUpdates":frameUpdates,"visible":gate.visible,"action":action.rawValue,"window":["width":panel.frame.width,"height":panel.frame.height],"displays":screens().map { ["width":$0.visibleFrame.width,"height":$0.visibleFrame.height] },"backingScale":panel.backingScaleFactor]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    func prepareToExit() {
        guard !gate.exiting else { return }
        gate.exiting=true; interaction.cancel(); playback.pause(); scheduler.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        view.onDown=nil; view.onMove=nil; view.onUp=nil
        panel.orderOut(nil); panel.close()
    }
}
