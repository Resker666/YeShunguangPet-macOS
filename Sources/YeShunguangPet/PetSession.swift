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
    private(set) var focusStatistics=FocusDailyStatistics()
    private(set) var focusStatisticsSaveError:String?
    private var focusStatisticsNeedsSave=false
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
    private(set) var isQuiet=false
    private(set) var focusQuiet=false
    private(set) var quietRevision:UInt64=0
    var onQuietChange:(()->Void)?
    var effectiveQuiet:Bool {isQuiet || focusQuiet}
    private var gaze=MouseGaze()
    private var nextGazeSample: Duration?
    private var gazeSamples=0
    private var menuOpen=false,settingsOpen=false,chatPresented=false
    private(set) var skinRevision: UInt64 = 0
    private let pointerPosition: () -> CGPoint
    private let automaticRandom: () -> Double
    private var automatic: AutomaticActions
    private var isAutomaticAction=false,automaticActionCount=0
    private let roamingRandom: () -> Double
    private var roaming: PetRoaming
    private var roamingMoved=false,roamingCount=0,roamingPointerSamples=0
    private var roamingDistance: CGFloat=0
    private var roamingPlacement: PlacementSnapshot?
    private var speech=SpeechPolicy()
    private var speechBubble:SpeechBubble?
    private var speechDeadline:Duration?
    private var speechShownCount=0
    var gazeDirection: Int? { gaze.direction }
    var supportsGaze: Bool { skin.manifest.lookDirections.count==16 }
    var supportsRoaming: Bool { skin.manifest.animations[.runningLeft]?.loop==true && skin.manifest.animations[.runningRight]?.loop==true }
    private var canSampleGaze: Bool { gate.shouldRunFrames && !effectiveQuiet && preferences.lookAtMouse && supportsGaze && action == .idle && !roaming.isWalking && !interaction.isPointerBusy && !menuOpen && !settingsOpen && !chatPresented }
    private var canRunAutomatic: Bool { gate.shouldRunFrames && !effectiveQuiet && action == .idle && !roaming.isWalking && !interaction.isPointerBusy && !menuOpen && !settingsOpen && !chatPresented }
    private var canRoam: Bool { gate.shouldRunFrames && !effectiveQuiet && !preferences.positionLocked && !interaction.isPointerBusy && !menuOpen && !settingsOpen && !chatPresented && (action == .idle || roaming.isWalking) }
    var canPresentFocusCompletion:Bool {gate.shouldRunFrames && !effectiveQuiet && !menuOpen && !settingsOpen && !interaction.isPointerBusy && action == .idle}
    func setFocusQuiet(_ enabled:Bool) {
        guard !gate.exiting,focusQuiet != enabled else{return}
        focusQuiet=enabled;quietRevision &+= 1
        onQuietChange?()
        if enabled{cancelInput()}else{reschedule()}
        onStatusChange?()
    }
    func setQuiet(_ quiet:Bool) {
        guard !gate.exiting,quiet != isQuiet else{return}
        isQuiet=quiet;quietRevision &+= 1;onQuietChange?();cancelInput();onStatusChange?()
    }
    func setMenuOpen(_ open: Bool) {
        guard !gate.exiting,menuOpen != open else { return }; menuOpen=open; cancelInput()
    }
    func setSettingsOpen(_ open: Bool) {
        guard !gate.exiting,settingsOpen != open else { return }; settingsOpen=open; cancelInput()
    }
    func setChatPresented(_ presented: Bool) {
        guard !gate.exiting, chatPresented != presented else { return }
        chatPresented = presented; cancelInput()
    }
    lazy var scheduler=FrameScheduler(now:now) { [weak self] in self?.tick() }
    init(skin: LoadedSkin, defaultSkin: LoadedSkin? = nil, now: @escaping () -> Duration, settings: SettingsStore, screens: @escaping () -> [ScreenArea], pointerPosition: @escaping () -> CGPoint = { NSEvent.mouseLocation }, automaticRandom: @escaping () -> Double = { Double.random(in:0..<1) },roamingRandom: @escaping () -> Double = { Double.random(in:0..<1) }) {
        self.settings=settings; self.screens=screens; self.startedAt=now()
        self.pointerPosition=pointerPosition
        self.automaticRandom=automaticRandom; automatic=AutomaticActions(manifest:skin.manifest,random:automaticRandom)
        self.roamingRandom=roamingRandom;roaming=PetRoaming(random:roamingRandom)
        self.defaultSkin=defaultSkin ?? skin; library=SkinLibrary(directory:settings.url.deletingLastPathComponent().appendingPathComponent("Skins",isDirectory:true))
        self.skin=skin; self.now=now; atlas=SpriteAtlas(skin:skin)
        let size=CGSize(width:skin.manifest.cellWidth,height:skin.manifest.cellHeight)
        panel=PetPanel(size:size); view=PetView(frame:CGRect(origin:.zero,size:size))
        playback=SpritePlayback(now:now); interaction=PetInteraction(doubleClickInterval:.seconds(NSEvent.doubleClickInterval),now:now)
        super.init(); gate.loaded=true; panel.contentView=view
        playback.start(skin.manifest.animations[.idle]!)
        view.onDown = { [weak self] point,count in guard let self,self.gate.shouldRunFrames else { return }; self.dismissSpeech(); self.stopRoaming(); self.cancelAutomaticAction(); self.interaction.pointerDown(at:point,clickCount:count); self.reschedule() }
        view.onMove = { [weak self] point in
            guard let self else{return}
            let effects=self.interaction.pointerMoved(to:point)
            // A locked drag is cancelled, so its mouse-up cannot become a click.
            if self.preferences.positionLocked && !effects.isEmpty {self.interaction.cancel()}
            else {self.apply(effects)}
            self.reschedule()
        }
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
        case .loaded(let saved): placement=saved.placement; preferences=saved.preferences; selectedSkinID=saved.selectedSkinID;focusStatistics=saved.focusStatistics
        case .missing: break
        case .protectedFile(let message): persistenceError=message; protectedSettings=true
        }
        if restoringSkin,let id=selectedSkinID {
            do {
                skin=try library.load(id:id); atlas=SpriteAtlas(skin:skin)
                playback.start(skin.manifest.animations[.idle]!)
            } catch { selectedSkinID=nil; skinWarning="上次使用的皮肤无法读取，已恢复默认角色：\(error.localizedDescription)" }
        }
        automatic=AutomaticActions(manifest:skin.manifest,random:automaticRandom)
        roaming=PetRoaming(random:roamingRandom)
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
        do { try saveSettings(PetSettings(placement:nextPlacement,preferences:preferences,selectedSkinID:id)) }
        catch { persistenceError=error.localizedDescription; onStatusChange?(); throw error }
        // Persistence is committed before touching the current image or playback.
        let nextAutomatic=AutomaticActions(manifest:next.manifest,random:automaticRandom)
        if next.directory != skin.directory || !automatic.hasSameRules(as:nextAutomatic) {
            automatic=nextAutomatic
        }
        skinRevision &+= 1
        scheduler.cancel(); skin=next; atlas=nextAtlas; selectedSkinID=id; skinWarning=nil; persistenceError=nil
        roaming=PetRoaming(random:roamingRandom)
        action = .idle; playback.start(animation); frame=first; view.image=image; frameUpdates += 1
        applyWindowPreferences(); applyPlacement(nextPlacement); synchronize(); onStatusChange?()
    }
    func setPreferences(_ value: PetPreferences) {
        guard !gate.exiting,value.isValid,value.keyboardShortcuts==preferences.keyboardShortcuts,value.focusMinutes==preferences.focusMinutes,value.breakMinutes==preferences.breakMinutes,value.speechOverrides==preferences.speechOverrides,value.focusWindow==preferences.focusWindow,value.focusCompletionSound==preferences.focusCompletionSound,value != preferences else { return }
        cancelInput()
        preferences=value; applyWindowPreferences()
        applyPlacement(WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()))
        synchronize()
        _=savePosition()
    }
    func saveKeyboardShortcuts(_ bindings:[ShortcutBinding])throws {
        guard !gate.exiting,!protectedSettings else{throw SkinError("配置受保护或正在退出，快捷键未更改。")}
        try KeyboardShortcuts.validate(bindings)
        var candidate=preferences;candidate.keyboardShortcuts=bindings
        let current=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()) ?? placement
        do {
            try saveSettings(PetSettings(placement:current,preferences:candidate,selectedSkinID:selectedSkinID))
            preferences=candidate;placement=current;persistenceError=nil;onStatusChange?()
        }catch{persistenceError=error.localizedDescription;onStatusChange?();throw error}
    }
    func commitCompanionPreferences(_ candidate:PetPreferences)throws {
        guard !gate.exiting,!protectedSettings,candidate.isValid,candidate.keyboardShortcuts==preferences.keyboardShortcuts else{throw SkinError("配置受保护、内容无效或正在退出，未保存。")}
        let current=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()) ?? placement
        do {
            try saveSettings(PetSettings(placement:current,preferences:candidate,selectedSkinID:selectedSkinID))
            preferences=candidate;placement=current;persistenceError=nil;onStatusChange?()
        }catch{persistenceError=error.localizedDescription;onStatusChange?();throw error}
    }
    private func saveSettings(_ candidate:PetSettings)throws {
        do {
            try settings.save(.init(placement:candidate.placement,preferences:candidate.preferences,selectedSkinID:candidate.selectedSkinID,focusStatistics:focusStatistics))
            focusStatisticsNeedsSave=false;focusStatisticsSaveError=nil
        }catch{
            if focusStatisticsNeedsSave{focusStatisticsSaveError=error.localizedDescription}
            throw error
        }
    }
    func recordFocusCompletion(minutes:Int,on day:String) {
        guard !gate.exiting else{return}
        do {
            focusStatistics=try focusStatistics.recording(minutes:minutes,on:day)
            focusStatisticsNeedsSave=true
            _=savePosition()
        }catch{focusStatisticsSaveError=error.localizedDescription;onStatusChange?()}
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
        do { try saveSettings(PetSettings(placement:placement,preferences:preferences,selectedSkinID:selectedSkinID)); persistenceError=nil; onStatusChange?(); return true }
        catch { persistenceError=error.localizedDescription; onStatusChange?(); return false }
    }
    func retrySave() { _=savePosition() }
    func resetProtectedSettings() {
        do { try settings.backupAndReset(); protectedSettings=false; _=savePosition() }
        catch { persistenceError=error.localizedDescription; onStatusChange?() }
    }
    func requestExit() -> Bool { stopRoaming();return savePosition() }
    func play(_ requested: PetAction) { startAction(requested,automatic:false) }
    private func startAction(_ requested: PetAction, automatic: Bool) {
        guard !gate.exiting else { return }
        dismissSpeech()
        stopRoaming()
        isAutomaticAction=automatic
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
        dismissSpeech()
        stopRoaming()
        cancelAutomaticAction()
        let wasLooking=gaze.direction != nil
        gaze.reset(); nextGazeSample=nil
        if wasLooking && gate.shouldRunFrames { playback.resume(); render() }
        if interaction.cancel() { finishDrag(); play(.idle) }
        reschedule()
    }
    private func cancelAutomaticAction() {
        guard isAutomaticAction else { return }
        isAutomaticAction=false; action = .idle
        playback.start(skin.manifest.animations[.idle]!); render()
    }
    private func stopRoaming() {
        guard roaming.isWalking else { return }
        roaming.cancel(at:now());setRoamingAnimation(.idle);saveRoamingPosition()
    }
    private func saveRoamingPosition() {
        guard roamingMoved else { return }
        roamingMoved=false
        // A display change can interrupt motion before the screen handler restores placement.
        if let current=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()) {
            applyPlacement(current)
        } else if let remembered=roamingPlacement {
            placement=PlacementSnapshot(screenID:remembered.screenID,origin:panel.frame.origin,visibleFrame:remembered.visibleFrame)
        }
        roamingPlacement=nil
        _ = savePosition()
    }
    private func setRoamingAnimation(_ next: PetAction) {
        gaze.reset();nextGazeSample=nil
        guard action != next else { return }
        action=next;isAutomaticAction=false;playback.start(skin.manifest.animations[next]!);render()
    }
    private func currentRoamingPlacement() -> PlacementSnapshot? {
        guard let current=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens()),current.origin==panel.frame.origin else { return nil }
        return current
    }
    private func updateRoaming() {
        let enabled=preferences.desktopRoaming && supportsRoaming && !preferences.positionLocked
        if roaming.isWalking && (!enabled || !canRoam) { stopRoaming() }
        roaming.update(enabled:enabled,intervalSeconds:preferences.roamIntervalSeconds,available:canRoam,at:now())
    }
    private func advanceRoaming() {
        updateRoaming()
        guard let deadline=roaming.nextDeadline,now()>=deadline else { return }
        let wasWalking=roaming.isWalking,radius:CGFloat=roaming.isPaused ? 100 : 80
        let frame=panel.frame,current=currentRoamingPlacement()
        if let sample=roaming.step(at:now(),frame:frame,area:current?.visibleFrame ?? .zero,cursorNear:{
            self.roamingPointerSamples += 1
            return AutomaticActions.isCursorNear(self.pointerPosition(),bounds:frame,radius:radius)
        }) {
            if !wasWalking && roaming.isWalking { dismissSpeech();roamingCount += 1;roamingMoved=false;roamingPlacement=current }
            if sample.x != frame.minX {
                panel.setFrameOrigin(CGPoint(x:sample.x,y:frame.minY))
                let distance=abs(panel.frame.minX-frame.minX)
                if distance>0 { roamingMoved=true;roamingDistance += distance }
            }
            setRoamingAnimation(sample.isFinished || sample.isPaused ? .idle : sample.direction>0 ? .runningRight : .runningLeft)
            if sample.isFinished { saveRoamingPosition() }
        }
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
            case .finishDrag: finishDrag(snapping:preferences.snapToEdges); play(.idle);requestSpeech(.drag)
            case .play(let requested): play(requested);if requested == .waving {requestSpeech(.click)}
            }
        }
    }
    func finishDrag(snapping:Bool=false) {
        applyPlacement(WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens(),snapToEdges:snapping))
        _=savePosition()
    }
    func requestSpeech(_ event:SpeechEvent) {
        var candidate=speech
        guard gate.shouldRunFrames,preferences.speechEnabled,!effectiveQuiet,!menuOpen,!settingsOpen,!chatPresented,!interaction.isPointerBusy,
              let text=candidate.select(lines:PersonalSpeech.resolve(id:skin.manifest.id,skin:skin.manifest.speech,overrides:preferences.speechOverrides),event:event,at:now()),
              let area=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens())?.visibleFrame else{return}
        if speechBubble==nil {speechBubble=SpeechBubble()}
        if speechBubble?.show(text,owner:panel,area:area)==true {speech=candidate;speechDeadline=now() + .seconds(6);speechShownCount += 1}
    }
    func presentChatReply(_ text: String) {
        guard canPresentFocusCompletion else { return }
        play(.waving)
        guard preferences.speechEnabled,
              let area=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:screens())?.visibleFrame else { return }
        if speechBubble == nil { speechBubble = SpeechBubble() }
        if speechBubble?.show(ChatText.excerpt(text),owner:panel,area:area) == true {
            speechDeadline = now() + .seconds(6); speechShownCount += 1; reschedule()
        }
    }
    private func dismissSpeech() {speechDeadline=nil;speechBubble?.dismiss()}
    private func render() {
        var sample=playback.sample()
        if sample.completed { action = .idle; isAutomaticAction=false; playback.start(skin.manifest.animations[.idle]!); sample=playback.sample() }
        let animation=skin.manifest.animations[action]!
        let location=gaze.direction.map { skin.manifest.lookDirections[$0] } ?? FrameLocation(row:animation.row,column:animation.startColumn+sample.index)
        if location != frame {
            do { view.image=try atlas.frame(at:location); frame=location; frameUpdates += 1 }
            catch { setVisible(false) }
        }
    }
    func tick() {
        guard gate.shouldRunFrames else { return }
        if let deadline=speechDeadline,now()>=deadline {dismissSpeech()}
        apply(interaction.expireClick()); render()
        advanceRoaming()
        updateAutomatic()
        if let next=automatic.takeAction(at:now(),cursorNear:{ AutomaticActions.isCursorNear(self.pointerPosition(),bounds:self.panel.frame) }) {
            automaticActionCount += 1; startAction(next,automatic:true)
        }
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
        updateRoaming()
        updateAutomatic()
        guard gate.shouldRunFrames else { gaze.reset(); nextGazeSample=nil; scheduler.cancel(); return }
        if updateGaze(allowSample:false) { render() }
        var delay=gaze.direction==nil ? playback.sample().untilNextFrame : nil
        if let deadline=interaction.nextClickDeadline { let click=max(.zero,deadline-now()); delay=delay.map{min($0,click)} ?? click }
        if let deadline=nextGazeSample { let look=max(.zero,deadline-now()); delay=delay.map{min($0,look)} ?? look }
        if let deadline=automatic.nextDeadline { let wait=max(.zero,deadline-now()); delay=delay.map{min($0,wait)} ?? wait }
        if let deadline=roaming.nextDeadline { let move=max(.zero,deadline-now());delay=delay.map{min($0,move)} ?? move }
        if let deadline=speechDeadline {let expiry=max(.zero,deadline-now());delay=delay.map{min($0,expiry)} ?? expiry}
        scheduler.schedule(after:delay)
    }
    private func updateAutomatic() {
        automatic.update(enabled:preferences.automaticActions,intervalSeconds:preferences.automaticActionIntervalSeconds,available:canRunAutomatic,at:now())
    }
    func exportMetrics(to url: URL) throws {
        let duration=now()-startedAt
        let seconds=Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18
        var data: [String:Any] = ["schemaVersion":1,"durationSeconds":seconds,"schedulerWakes":scheduler.wakeCount,"frameUpdates":frameUpdates,"visible":gate.visible,"action":action.rawValue,"skinID":skin.manifest.id,"window":["width":panel.frame.width,"height":panel.frame.height],"displays":screens().map { ["width":$0.visibleFrame.width,"height":$0.visibleFrame.height] },"backingScale":panel.backingScaleFactor,"lookAtMouseEnabled":preferences.lookAtMouse,"gazeSamples":gazeSamples]
        if let direction=gaze.direction { data["gazeDirection"]=direction }
        data["automaticActionsEnabled"]=preferences.automaticActions
        data["automaticActionIntervalSeconds"]=preferences.automaticActionIntervalSeconds
        data["automaticActionCount"]=automaticActionCount
        data["desktopRoamingEnabled"]=preferences.desktopRoaming
        data["roamIntervalSeconds"]=preferences.roamIntervalSeconds
        data["roamingCount"]=roamingCount;data["roamingDistancePoints"]=roamingDistance;data["roamingPointerSamples"]=roamingPointerSamples
        data["quietMode"]=isQuiet
        data["speechEnabled"]=preferences.speechEnabled;data["speechShownCount"]=speechShownCount;data["speechVisible"]=speechDeadline != nil
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    func prepareToExit() {
        guard !gate.exiting else { return }
        dismissSpeech();speechBubble?.close();speechBubble=nil
        gate.exiting=true; gaze.reset(); nextGazeSample=nil; interaction.cancel(); playback.pause(); scheduler.cancel()
        roaming.update(enabled:false,intervalSeconds:preferences.roamIntervalSeconds,available:false,at:now())
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        view.onDown=nil; view.onMove=nil; view.onUp=nil
        panel.orderOut(nil); panel.close()
    }
}
