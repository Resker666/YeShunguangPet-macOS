import AppKit

@MainActor final class FrameScheduler {
    private let now: () -> Duration, onFire: () -> Void
    private var timer: Timer?
    private var generation=0
    private(set) var wakeCount=0
    private(set) var scheduledDeadline:Duration?
    var pendingCount: Int { timer == nil ? 0 : 1 }
    init(now: @escaping () -> Duration, onFire: @escaping () -> Void) { self.now=now; self.onFire=onFire }
    func cancel() { generation += 1; timer?.invalidate(); timer=nil;scheduledDeadline=nil }
    func schedule(after delay: Duration?) {
        cancel(); guard let delay else { return }
        let epoch=generation, deadline=now()+max(.zero,delay)
        scheduledDeadline=deadline
        let seconds=Double(delay.components.seconds)+Double(delay.components.attoseconds)/1e18
        let next=Timer(timeInterval:max(0.001,seconds),repeats:false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,self.generation==epoch else { return }
                self.timer=nil;self.scheduledDeadline=nil
                if self.now()<deadline { self.schedule(after:deadline-self.now()); return }
                self.wakeCount += 1; self.onFire()
            }
        }
        next.tolerance=min(0.005,max(0,seconds*0.05)); timer=next
        RunLoop.main.add(next,forMode:.common)
    }
}
