import Foundation

public enum FocusPhase:String,Sendable {case focus,rest}
public enum FocusStatus:String,Sendable {case ready,running,paused,completed}
public struct FocusTimer {
    public private(set) var phase:FocusPhase = .focus
    public private(set) var status:FocusStatus = .ready
    public private(set) var deadline:Duration?
    private var focusMinutes=25,breakMinutes=5
    private var storedRemaining:Duration = .seconds(1500)
    public init(){}
    public var duration:Duration {.seconds((phase == .focus ? focusMinutes : breakMinutes)*60)}
    public func remaining(at now:Duration)->Duration {
        if status == .running,let deadline{return min(duration,max(.zero,deadline-now))}
        return storedRemaining
    }
    public mutating func configure(focusMinutes:Int,breakMinutes:Int)throws {
        guard status == .ready else{throw SkinError("请先重置计时，再修改时长。")}
        guard (1...120).contains(focusMinutes),(1...60).contains(breakMinutes) else{throw SkinError("专注请输入1–120分钟，休息请输入1–60分钟。")}
        self.focusMinutes=focusMinutes;self.breakMinutes=breakMinutes;storedRemaining=duration
    }
    @discardableResult public mutating func startOrResume(at now:Duration)->FocusPhase? {
        if status == .running{return advance(at:now)}
        if status == .completed {phase = phase == .focus ? .rest : .focus;storedRemaining=duration}
        if status == .ready {storedRemaining=duration}
        deadline=now+storedRemaining;status = .running;return nil
    }
    @discardableResult public mutating func pause(at now:Duration)->FocusPhase? {
        if let completed=advance(at:now){return completed}
        guard status == .running else{return nil}
        storedRemaining=remaining(at:now);deadline=nil;status = .paused;return nil
    }
    @discardableResult public mutating func advance(at now:Duration)->FocusPhase? {
        guard status == .running,let deadline,now>=deadline else{return nil}
        storedRemaining = .zero;self.deadline=nil;status = .completed;return phase
    }
    public mutating func reset() {phase = .focus;status = .ready;deadline=nil;storedRemaining=duration}
}
