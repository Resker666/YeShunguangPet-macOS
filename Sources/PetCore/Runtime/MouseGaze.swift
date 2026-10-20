import Foundation
import CoreGraphics

public struct MouseGaze {
    public private(set) var direction: Int?
    private var startedAt: Duration?
    private var exhausted=false
    public init() {}
    public static func direction(pointer: CGPoint,bounds: CGRect) -> Int? {
        guard [pointer.x,pointer.y,bounds.origin.x,bounds.origin.y,bounds.width,bounds.height,bounds.midX,bounds.midY].allSatisfy({$0.isFinite}),bounds.width>0,bounds.height>0 else { return nil }
        let dx=pointer.x-bounds.midX,dy=pointer.y-bounds.midY,distance=hypot(dx,dy)
        guard distance>=42,distance<=520 else { return nil }
        // AppKit's global y increases upward, unlike Windows screen coordinates.
        var angle=atan2(dx,dy)
        if angle<0 { angle += 2 * .pi }
        return Int((angle / (.pi/8)).rounded(.toNearestOrAwayFromZero)) % 16
    }
    public mutating func sample(pointer: CGPoint,bounds: CGRect,at now: Duration) -> Int? {
        guard let next=Self.direction(pointer:pointer,bounds:bounds) else { reset(); return nil }
        if let startedAt,now-startedAt >= .seconds(2) { exhausted=true }
        guard !exhausted else { direction=nil; return nil }
        if startedAt==nil { startedAt=now }
        direction=next; return next
    }
    public mutating func reset() { direction=nil; startedAt=nil; exhausted=false }
}
