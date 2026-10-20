import Foundation

public struct AutomaticActions {
    public private(set) var nextDeadline: Duration?
    private let rules: [PetBehaviorRule]
    private let random: () -> Double
    private var lastPlayed: [Int:Duration]=[:]
    private var enabled=false,available=false
    private var intervalSeconds=60
    private var remaining: Duration?
    private var intervalDeadline: Duration?
    public init(manifest: PetManifest, random: @escaping () -> Double = { Double.random(in:0..<1) }) {
        self.random=random
        // An explicit empty rule list suppresses the legacy fallback.
        rules=manifest.behavior?.rules ?? [PetAction.waving,.jumping].compactMap { action in
            guard let animation=manifest.animations[action],!animation.loop,animation.durationsMs.reduce(0,+)<=30000 else { return nil }
            return PetBehaviorRule(condition:"any",action:action,weight:1,cooldownSeconds:0)
        }
    }
    public func hasSameRules(as other: AutomaticActions) -> Bool { rules==other.rules }
    public mutating func update(enabled: Bool, intervalSeconds: Int, available: Bool, at now: Duration) {
        let enabled=enabled && !rules.isEmpty
        let changed=enabled != self.enabled || intervalSeconds != self.intervalSeconds
        self.enabled=enabled; self.intervalSeconds=intervalSeconds
        if !enabled { nextDeadline=nil; remaining=nil; intervalDeadline=nil }
        else if changed {
            remaining=nextDelay(); intervalDeadline=available ? now+remaining! : nil; nextDeadline=intervalDeadline
        }
        else if available != self.available {
            if available { intervalDeadline=now+(remaining ?? nextDelay()); nextDeadline=intervalDeadline }
            else { remaining=intervalDeadline.map { max(.zero,$0-now) }; intervalDeadline=nil; nextDeadline=nil }
        }
        self.available=available
    }
    public mutating func takeAction(at now: Duration, cursorNear: () -> Bool) -> PetAction? {
        guard enabled,available,let deadline=nextDeadline,now>=deadline else { return nil }
        let eligible=rules.indices.filter { index in
            lastPlayed[index].map { now >= $0 + .seconds(rules[index].cooldownSeconds) } ?? true
        }
        guard !eligible.isEmpty else {
            nextDeadline=rules.indices.compactMap { index in lastPlayed[index].map { $0 + .seconds(rules[index].cooldownSeconds) } }.min()
            return nil
        }
        lazy var near=cursorNear()
        let matching=eligible.filter { rules[$0].condition=="any" || (rules[$0].condition=="cursorNear" ? near : !near) }
        guard !matching.isEmpty else { nextDeadline=now + .milliseconds(500); return nil }
        var draw=unitRandom()*Double(matching.reduce(0) { $0+rules[$1].weight })
        var selected=matching.last!
        for index in matching {
            draw -= Double(rules[index].weight)
            if draw<0 { selected=index; break }
        }
        lastPlayed[selected]=now; intervalDeadline=now+nextDelay(); nextDeadline=intervalDeadline
        return rules[selected].action
    }
    private func unitRandom() -> Double { min(max(random(),0),1.nextDown) }
    private func nextDelay() -> Duration { .seconds(Double(intervalSeconds)*(0.75+unitRandom()*0.5)) }
    public static func isCursorNear(_ pointer: CGPoint, bounds: CGRect) -> Bool {
        let dx=max(bounds.minX-pointer.x,0,pointer.x-bounds.maxX)
        let dy=max(bounds.minY-pointer.y,0,pointer.y-bounds.maxY)
        return hypot(dx,dy)<=80
    }
}
