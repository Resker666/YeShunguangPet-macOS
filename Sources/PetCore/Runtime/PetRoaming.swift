import Foundation

public struct RoamingSample {
    public let x: CGFloat,direction: Int,isPaused: Bool,isFinished: Bool
}
public struct PetRoaming {
    public private(set) var nextDeadline: Duration?
    public private(set) var isWalking=false,isPaused=false
    private let random: () -> Double
    private var enabled=false,available=false,intervalSeconds=75
    private var remaining: Duration?,lastStep: Duration?
    private var direction=1,target: CGFloat=0,position: CGFloat=0
    private var area=CGRect.zero,size=CGSize.zero
    public init(random: @escaping () -> Double = { Double.random(in:0..<1) }) { self.random=random }
    public mutating func update(enabled: Bool,intervalSeconds: Int,available: Bool,at now: Duration) {
        let changed=enabled != self.enabled || intervalSeconds != self.intervalSeconds
        self.enabled=enabled;self.intervalSeconds=intervalSeconds
        if !enabled { isWalking=false;isPaused=false;nextDeadline=nil;remaining=nil;lastStep=nil }
        else if changed { cancel(at:now);if !available { remaining=nextDeadline.map{max(.zero,$0-now)};nextDeadline=nil } }
        else if available != self.available {
            if available { nextDeadline=now+(remaining ?? delay()) }
            else {
                if isWalking { cancel(at:now) }
                remaining=nextDeadline.map{max(.zero,$0-now)};nextDeadline=nil
            }
        }
        self.available=available
    }
    public mutating func step(at now: Duration,frame: CGRect,area: CGRect,cursorNear: () -> Bool) -> RoamingSample? {
        guard enabled,available,let deadline=nextDeadline,now>=deadline else { return nil }
        if !isWalking {
            let valid=[frame.minX,frame.minY,frame.width,frame.height,area.minX,area.minY,area.width,area.height].allSatisfy{$0.isFinite}
            let left=frame.minX-area.minX,right=area.maxX-frame.maxX
            guard valid,frame.width>0,frame.height>0,area.contains(frame),max(left,right)>=24 else { cancel(at:now);return nil }
            if cursorNear() { nextDeadline=now + .milliseconds(500);return nil }
            direction=left>=24 && right>=24 ? (unit()<0.5 ? -1 : 1) : (right>=left ? 1 : -1)
            let distance=min(60+unit()*60,direction>0 ? right : left)
            position=frame.minX;target=position+CGFloat(direction)*distance;self.area=area;size=frame.size
            isWalking=true;isPaused=false;lastStep=now;nextDeadline=now + .milliseconds(33)
            return .init(x:frame.minX,direction:direction,isPaused:false,isFinished:false)
        }
        guard area==self.area,frame.size==size,area.contains(frame) else {
            cancel(at:now);return .init(x:frame.minX,direction:direction,isPaused:false,isFinished:true)
        }
        let elapsed=now-(lastStep ?? now);lastStep=now
        if cursorNear() {
            isPaused=true;nextDeadline=now + .milliseconds(100)
            return .init(x:frame.minX,direction:direction,isPaused:true,isFinished:false)
        }
        isPaused=false
        let seconds=min(0.1,max(0,Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18))
        let distance=min(abs(target-position),40*seconds)
        let x=position+CGFloat(direction)*distance;position=x
        let finished=abs(target-x)<0.000001
        if finished { cancel(at:now) } else { nextDeadline=now + .milliseconds(33) }
        return .init(x:finished ? target : x,direction:direction,isPaused:false,isFinished:finished)
    }
    public mutating func cancel(at now: Duration) {
        isWalking=false;isPaused=false;lastStep=nil
        remaining=nil;nextDeadline=enabled ? now+delay() : nil
    }
    private func unit() -> Double { min(max(random(),0),1.nextDown) }
    private func delay() -> Duration { .seconds(Double(intervalSeconds)*(0.75+unit()*0.5)) }
}
