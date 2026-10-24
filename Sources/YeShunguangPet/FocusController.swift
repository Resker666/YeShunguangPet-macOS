import AppKit
import Combine
import PetCore

struct FocusSnapshot:Equatable {
    let phase:FocusPhase,status:FocusStatus
    let remainingSeconds:Int,durationSeconds:Int
    var timeText:String {String(format:"%02d:%02d",remainingSeconds/60,remainingSeconds%60)}
    var phaseName:String {phase == .focus ? "专注" : "休息"}
    var statusText:String {
        switch status {case .ready:return "准备\(phaseName)";case .running:return "\(phaseName)中";case .paused:return "\(phaseName)已暂停";case .completed:return "\(phaseName)完成"}
    }
    var primaryTitle:String {
        switch status {
        case .ready:return "开始\(phaseName)"
        case .running:return "暂停\(phaseName)"
        case .paused:return "继续\(phaseName)"
        case .completed:return phase == .focus ? "开始休息" : "开始专注"
        }
    }
}
struct FocusCommand:Hashable {
    enum Kind:Hashable {case startOrResume,pause}
    let kind:Kind,generation:UInt64
}
struct FocusPresetCommand:Hashable {let minutes:Int,generation:UInt64}

@MainActor final class FocusController:NSObject,ObservableObject {
    @Published private(set) var snapshot=FocusSnapshot(phase:.focus,status:.ready,remainingSeconds:1500,durationSeconds:1500)
    @Published private(set) var completionSoundEnabled=false
    @Published private(set) var todayStatistics=FocusDailyStatistics()
    @Published private(set) var statisticsSaveError:String?
    @Published private(set) var presetError:String?
    static let presetMinutes=[15,25,45,60]
    private var policy=FocusTimer()
    private weak var session:PetSession?
    private let now:()->Duration
    private let wallNow:()->Date,timeZone:()->TimeZone
    private var displaySources=Set<String>()
    private var sleeping=false,terminating=false,disposed=false
    @Published private(set) var actionRevision:UInt64=0
    private var cachedFocusMinutes:Int?,cachedBreakMinutes:Int?
    private var suppressCompletionSound=false
    private let playCompletionSound:()->Void
    var canPlayCompletionSound:()->Bool = {NSApp.modalWindow==nil}
    var allowsCompletionAudio:()->Bool = {true}
    var onChange:(()->Void)?
    var phase:FocusPhase {snapshot.phase}
    var status:FocusStatus {snapshot.status}
    var remainingSeconds:Int {snapshot.remainingSeconds}
    var primaryCommand:FocusCommand {.init(kind:status == .running ? .pause : .startOrResume,generation:actionRevision)}
    func presetCommand(minutes:Int)->FocusPresetCommand {.init(minutes:minutes,generation:actionRevision)}
    var canStartPreset:Bool {canOperate && !sleeping && session?.gate.sleeping==false && canPlayCompletionSound() && policy.status == .ready}
    func startPreset(_ command:FocusPresetCommand) {
        guard canStartPreset,command.generation==actionRevision,Self.presetMinutes.contains(command.minutes) else{return}
        do {
            try applyDurations(focusMinutes:command.minutes,breakMinutes:breakMinutes)
            presetError=nil;startOrResume()
        }catch{presetError=error.localizedDescription}
        onChange?()
    }
    func perform(_ command:FocusCommand) {
        guard canOperate else{return}
        guard command.generation==actionRevision else{refreshTime();return}
        switch command.kind{case .pause:pause();case .startOrResume:startOrResume()}
    }
    var focusMinutes:Int {session?.preferences.focusMinutes ?? 25}
    var breakMinutes:Int {session?.preferences.breakMinutes ?? 5}
    var timeText:String {snapshot.timeText}
    var phaseName:String {snapshot.phaseName}
    var statusText:String {snapshot.statusText}
    var primaryTitle:String {snapshot.primaryTitle}
    lazy var scheduler=FrameScheduler(now:now) {[weak self] in self?.refreshTime()}
    init(session:PetSession,playCompletionSound:@escaping ()->Void = {_=NSSound(named:"Glass")?.play()},wallNow:@escaping ()->Date = {Date()},timeZone:@escaping ()->TimeZone = {.autoupdatingCurrent}) {
        self.session=session;self.now=session.now;self.playCompletionSound=playCompletionSound;self.wallNow=wallNow;self.timeZone=timeZone
        super.init();refreshConfiguration()
        let center=NSWorkspace.shared.notificationCenter
        center.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        center.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
        for name in [Notification.Name.NSCalendarDayChanged,.NSSystemClockDidChange,.NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(self,selector:#selector(calendarChanged),name:name,object:nil)
        }
    }
    private var canOperate:Bool {!disposed && !terminating && session?.gate.exiting==false}
    func refreshConfiguration() {
        refreshStatistics()
        let sound=session?.preferences.focusCompletionSound ?? false
        if completionSoundEnabled != sound{completionSoundEnabled=sound}
        guard canOperate else{return}
        if policy.status == .ready {try? policy.configure(focusMinutes:focusMinutes,breakMinutes:breakMinutes)}
        publishAndSchedule()
    }
    func startOrResume() {guard canOperate else{return};settle(policy.startOrResume(at:now()))}
    func pause() {guard canOperate else{return};settle(policy.pause(at:now()))}
    func reset() {guard canOperate else{return};policy.reset();refreshConfiguration()}
    func setCompletionSound(_ enabled:Bool)throws {
        guard canOperate,canPlayCompletionSound(),let session else{throw SkinError("当前无法修改提示音，请稍后重试。")}
        try session.saveFocusCompletionSound(enabled)
        refreshConfiguration()
    }
    func applyDurations(focusMinutes:Int,breakMinutes:Int)throws {
        guard canOperate,policy.status == .ready,let session else{throw SkinError("请先重置计时，再修改时长。")}
        try session.saveFocusDurations(focusMinutes:focusMinutes,breakMinutes:breakMinutes)
        try policy.configure(focusMinutes:focusMinutes,breakMinutes:breakMinutes)
        publishAndSchedule()
    }
    func refreshTime() {
        refreshStatistics()
        guard canOperate,!sleeping else{scheduler.cancel();return}
        settle(policy.advance(at:now()))
    }
    private func settle(_ completion:FocusPhase?) {
        if completion == .focus {session?.recordFocusCompletion(minutes:Int(policy.duration.components.seconds/60),on:currentDay)}
        refreshStatistics()
        publishAndSchedule()
        if let completion {
            if !suppressCompletionSound,!sleeping,canOperate,session?.gate.sleeping==false,session?.isQuiet==false,completionSoundEnabled,canPlayCompletionSound(),allowsCompletionAudio(){playCompletionSound()}
            session?.presentFocusCompletion(completion)
        }
    }
    private var currentDay:String {FocusDailyStatistics.dayKey(for:wallNow(),timeZone:timeZone())}
    func refreshStatistics() {
        guard !disposed else{return}
        let value=(session?.focusStatistics ?? .init()).forDay(currentDay)
        if todayStatistics != value{todayStatistics=value}
        let error=session?.focusStatisticsSaveError
        if statisticsSaveError != error{statisticsSaveError=error}
    }
    func retryStatisticsSaving(){guard canOperate,canPlayCompletionSound() else{return};session?.retrySave();refreshStatistics();onChange?()}
    // Foundation can post these notifications from a background queue, including at midnight.
    @objc nonisolated private func calendarChanged(_ notification:Notification) {
        if Thread.isMainThread {MainActor.assumeIsolated{refreshForCalendarChange()}}
        else {Task{@MainActor [weak self] in self?.refreshForCalendarChange()}}
    }
    private func refreshForCalendarChange(){guard !disposed else{return};refreshStatistics();onChange?()}
    private func publishAndSchedule() {
        let remaining=policy.remaining(at:now())
        let seconds=Double(remaining.components.seconds)+Double(remaining.components.attoseconds)/1e18
        let value=FocusSnapshot(phase:policy.phase,status:policy.status,remainingSeconds:max(0,Int(ceil(seconds))),durationSeconds:Int(policy.duration.components.seconds))
        let changed=value != snapshot
        let commandChanged=value.phase != snapshot.phase || value.status != snapshot.status || value.durationSeconds != snapshot.durationSeconds || cachedFocusMinutes != focusMinutes || cachedBreakMinutes != breakMinutes
        cachedFocusMinutes=focusMinutes;cachedBreakMinutes=breakMinutes
        if commandChanged{actionRevision &+= 1}
        if changed{snapshot=value}
        session?.setFocusQuiet(policy.phase == .focus && policy.status == .running && !disposed)
        scheduler.cancel()
        if canOperate,!sleeping,policy.status == .running,let deadline=policy.deadline {
            let remaining=max(.zero,deadline-now())
            scheduler.schedule(after:displaySources.isEmpty ? remaining : min(remaining,.seconds(1)))
        }
        if changed || commandChanged{onChange?()}
    }
    func setDisplayVisible(_ visible:Bool,source:String) {
        guard !disposed else{return}
        let changed=visible ? displaySources.insert(source).inserted : displaySources.remove(source) != nil
        if changed{refreshTime()}
    }
    private func reconcileWithoutSound() {
        let previous=suppressCompletionSound;suppressCompletionSound=true
        defer{suppressCompletionSound=previous};refreshTime()
    }
    func setSleeping(_ value:Bool) {guard !disposed else{return};let wasSleeping=sleeping;sleeping=value;if value{scheduler.cancel()}else if wasSleeping{reconcileWithoutSound()}else{refreshTime()}}
    func setTerminating(_ value:Bool) {guard !disposed else{return};let wasTerminating=terminating;terminating=value;if value{scheduler.cancel()}else if wasTerminating{reconcileWithoutSound()}else{refreshTime()}}
    @objc private func willSleep(_ notification:Notification){setSleeping(true)}
    @objc private func didWake(_ notification:Notification){setSleeping(false)}
    func dispose() {
        guard !disposed else{return};disposed=true;scheduler.cancel();displaySources.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self);onChange=nil;session?.setFocusQuiet(false)
        NotificationCenter.default.removeObserver(self)
    }
}
