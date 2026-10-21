import AppKit
import Combine
import PetCore

struct FocusSnapshot:Equatable {
    let phase:FocusPhase,status:FocusStatus
    let remainingSeconds:Int,durationSeconds:Int
}

@MainActor final class FocusController:NSObject,ObservableObject {
    @Published private(set) var snapshot=FocusSnapshot(phase:.focus,status:.ready,remainingSeconds:1500,durationSeconds:1500)
    private var policy=FocusTimer()
    private weak var session:PetSession?
    private let now:()->Duration
    private var displaySources=Set<String>()
    private var sleeping=false,terminating=false,disposed=false
    var onChange:(()->Void)?
    var phase:FocusPhase {snapshot.phase}
    var status:FocusStatus {snapshot.status}
    var remainingSeconds:Int {snapshot.remainingSeconds}
    var focusMinutes:Int {session?.preferences.focusMinutes ?? 25}
    var breakMinutes:Int {session?.preferences.breakMinutes ?? 5}
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
    lazy var scheduler=FrameScheduler(now:now) {[weak self] in self?.refreshTime()}
    init(session:PetSession) {
        self.session=session;self.now=session.now
        super.init();refreshConfiguration()
        let center=NSWorkspace.shared.notificationCenter
        center.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        center.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
    }
    private var canOperate:Bool {!disposed && !terminating && session?.gate.exiting==false}
    func refreshConfiguration() {
        guard canOperate,policy.status == .ready else{return}
        try? policy.configure(focusMinutes:focusMinutes,breakMinutes:breakMinutes)
        publishAndSchedule()
    }
    func startOrResume() {guard canOperate else{return};settle(policy.startOrResume(at:now()))}
    func pause() {guard canOperate else{return};settle(policy.pause(at:now()))}
    func reset() {guard canOperate else{return};policy.reset();refreshConfiguration()}
    func applyDurations(focusMinutes:Int,breakMinutes:Int)throws {
        guard canOperate,policy.status == .ready,let session else{throw SkinError("请先重置计时，再修改时长。")}
        try session.saveFocusDurations(focusMinutes:focusMinutes,breakMinutes:breakMinutes)
        try policy.configure(focusMinutes:focusMinutes,breakMinutes:breakMinutes)
        publishAndSchedule()
    }
    func refreshTime() {
        guard canOperate,!sleeping else{scheduler.cancel();return}
        settle(policy.advance(at:now()))
    }
    private func settle(_ completion:FocusPhase?) {
        publishAndSchedule()
        if let completion{session?.presentFocusCompletion(completion)}
    }
    private func publishAndSchedule() {
        let remaining=policy.remaining(at:now())
        let seconds=Double(remaining.components.seconds)+Double(remaining.components.attoseconds)/1e18
        let value=FocusSnapshot(phase:policy.phase,status:policy.status,remainingSeconds:max(0,Int(ceil(seconds))),durationSeconds:Int(policy.duration.components.seconds))
        let changed=value != snapshot
        if changed{snapshot=value}
        session?.setFocusQuiet(policy.phase == .focus && policy.status == .running && !disposed)
        scheduler.cancel()
        if canOperate,!sleeping,policy.status == .running,let deadline=policy.deadline {
            let remaining=max(.zero,deadline-now())
            scheduler.schedule(after:displaySources.isEmpty ? remaining : min(remaining,.seconds(1)))
        }
        if changed{onChange?()}
    }
    func setDisplayVisible(_ visible:Bool,source:String) {
        guard !disposed else{return}
        let changed=visible ? displaySources.insert(source).inserted : displaySources.remove(source) != nil
        if changed{refreshTime()}
    }
    func setSleeping(_ value:Bool) {guard !disposed else{return};sleeping=value;if value{scheduler.cancel()}else{refreshTime()}}
    func setTerminating(_ value:Bool) {guard !disposed else{return};terminating=value;if value{scheduler.cancel()}else{refreshTime()}}
    @objc private func willSleep(_ notification:Notification){setSleeping(true)}
    @objc private func didWake(_ notification:Notification){setSleeping(false)}
    func dispose() {
        guard !disposed else{return};disposed=true;scheduler.cancel();displaySources.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self);onChange=nil;session?.setFocusQuiet(false)
    }
}
