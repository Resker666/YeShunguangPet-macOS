import Foundation

public struct PlaybackSample: Equatable, Sendable {
    public let index: Int
    public let completed: Bool
    public let untilNextFrame: Duration?
}
public struct SpritePlayback {
    private let now: () -> Duration
    private var ends: [Int64]=[]
    private var started: Duration = .zero
    private var carried: Int64=0
    private var loop=false
    private var running=false
    public init(now: @escaping () -> Duration) { self.now=now }
    public mutating func start(_ animation: AnimationDefinition) {
        precondition(!animation.durationsMs.isEmpty && animation.durationsMs.count<=64 && animation.durationsMs.allSatisfy{(20...10000).contains($0)})
        var total:Int64=0
        ends=animation.durationsMs.map { total += Int64($0)*1_000_000; return total }
        loop=animation.loop; carried=0; started=now(); running=true
    }
    private func ticks(_ d: Duration) -> Int64 {
        let c=d.components
        if c.seconds>Int64.max/1_000_000_000 { return Int64.max }
        if c.seconds<0 { return 0 }
        let (result,overflow)=(c.seconds*1_000_000_000).addingReportingOverflow(c.attoseconds/1_000_000_000)
        return overflow ? Int64.max : max(0,result)
    }
    private func elapsed() -> Int64 {
        let delta=running ? ticks(now()-started) : 0
        let (result,overflow)=carried.addingReportingOverflow(delta)
        return overflow ? Int64.max : result
    }
    public mutating func pause() { guard running else { return }; carried=elapsed(); running=false }
    public mutating func resume() { guard !running && !ends.isEmpty else { return }; started=now(); running=true }
    public func sample() -> PlaybackSample {
        guard let total=ends.last else { return .init(index:0,completed:true,untilNextFrame:nil) }
        let time=elapsed()
        if !loop && time>=total { return .init(index:ends.count-1,completed:true,untilNextFrame:nil) }
        let position=loop ? time%total : time
        let index=ends.firstIndex(where:{$0>position}) ?? ends.count-1
        return .init(index:index,completed:false,untilNextFrame:running ? .nanoseconds(ends[index]-position) : nil)
    }
}
