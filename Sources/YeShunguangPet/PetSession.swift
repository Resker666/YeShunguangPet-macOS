import AppKit
import PetCore

@MainActor final class PetSession: NSObject {
    let skin: LoadedSkin, atlas: SpriteAtlas, panel: PetPanel, view: PetView
    let now: () -> Duration
    var playback: SpritePlayback
    let interaction: PetInteraction
    var gate=RuntimeGate()
    private(set) var action: PetAction = .idle
    private var frame: FrameLocation?
    private var dragOrigin=CGPoint.zero
    var onStatusChange: (() -> Void)?
    var isVisible: Bool { gate.visible }
    lazy var scheduler=FrameScheduler(now:now) { [weak self] in self?.tick() }
    init(skin: LoadedSkin, now: @escaping () -> Duration) {
        self.skin=skin; self.now=now; atlas=SpriteAtlas(skin:skin)
        let size=CGSize(width:skin.manifest.cellWidth,height:skin.manifest.cellHeight)
        panel=PetPanel(size:size); view=PetView(frame:CGRect(origin:.zero,size:size))
        playback=SpritePlayback(now:now); interaction=PetInteraction(doubleClickInterval:.seconds(NSEvent.doubleClickInterval),now:now)
        super.init(); gate.loaded=true; panel.contentView=view
        playback.start(skin.manifest.animations[.idle]!)
        view.onDown = { [weak self] point,count in guard let self,self.gate.shouldRunFrames else { return }; self.interaction.pointerDown(at:point,clickCount:count); self.reschedule() }
        view.onMove = { [weak self] point in guard let self else { return }; self.apply(self.interaction.pointerMoved(to:point)); self.reschedule() }
        view.onUp = { [weak self] point in guard let self else { return }; self.apply(self.interaction.pointerUp(at:point)); self.reschedule() }
        let center=NSWorkspace.shared.notificationCenter
        center.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        center.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.screensDidSleepNotification,object:nil)
        center.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
        center.addObserver(self,selector:#selector(didWake),name:NSWorkspace.screensDidWakeNotification,object:nil)
    }
    func start() { recall() }
    func recall() {
        cancelInput()
        if let area=NSScreen.screens.first?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x:max(area.minX,area.maxX-panel.frame.width-24),y:area.minY+24))
            setVisible(true); play(.waving)
        }
    }
    func play(_ requested: PetAction) {
        guard !gate.exiting else { return }
        let next=skin.manifest.resolve(requested)
        action=next; playback.start(skin.manifest.animations[next]!); render(); reschedule()
    }
    func setVisible(_ visible: Bool) {
        guard !gate.exiting else { return }
        cancelInput(); gate.visible=visible
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        synchronize(); onStatusChange?()
    }
    func setSleeping(_ sleeping: Bool) { guard !gate.exiting else { return }; cancelInput(); gate.sleeping=sleeping; synchronize() }
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
        if let area=(panel.screen ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x:min(max(area.minX,panel.frame.minX),max(area.minX,area.maxX-panel.frame.width)),y:min(max(area.minY,panel.frame.minY),max(area.minY,area.maxY-panel.frame.height))))
        }
    }
    private func render() {
        var sample=playback.sample()
        if sample.completed { action = .idle; playback.start(skin.manifest.animations[.idle]!); sample=playback.sample() }
        let animation=skin.manifest.animations[action]!
        let location=FrameLocation(row:animation.row,column:animation.startColumn+sample.index)
        if location != frame {
            do { view.image=try atlas.frame(at:location); frame=location }
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
    func prepareToExit() {
        guard !gate.exiting else { return }
        gate.exiting=true; interaction.cancel(); playback.pause(); scheduler.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        view.onDown=nil; view.onMove=nil; view.onUp=nil
        panel.orderOut(nil); panel.close()
    }
}
