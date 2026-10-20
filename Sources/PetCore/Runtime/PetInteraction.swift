import Foundation
import CoreGraphics

public enum InteractionEffect: Equatable { case beginDrag, drag(delta: CGSize), finishDrag, play(PetAction) }
public final class PetInteraction {
    private let interval: Duration, now: () -> Duration
    private var origin: CGPoint?
    private var doublePress=false, dragging=false
    public private(set) var nextClickDeadline: Duration?
    public var isPointerBusy: Bool { origin != nil || nextClickDeadline != nil }
    public init(doubleClickInterval: Duration, now: @escaping () -> Duration) { interval=doubleClickInterval; self.now=now }
    public func pointerDown(at point: CGPoint, clickCount: Int) { cancel(); origin=point; doublePress=clickCount>=2 }
    public func pointerMoved(to point: CGPoint) -> [InteractionEffect] {
        guard let origin else { return [] }
        let delta=CGSize(width:point.x-origin.x,height:point.y-origin.y)
        guard dragging || abs(delta.width)>4 || abs(delta.height)>4 else { return [] }
        let begin = !dragging; dragging=true; nextClickDeadline=nil
        return (begin ? [.beginDrag] : [])+[.drag(delta:delta)]
    }
    public func pointerUp(at point: CGPoint) -> [InteractionEffect] {
        guard origin != nil else { return [] }; origin=nil
        if dragging { dragging=false; return [.finishDrag] }
        if doublePress { nextClickDeadline=nil; return [.play(.jumping)] }
        nextClickDeadline=now()+interval; return []
    }
    public func expireClick() -> [InteractionEffect] {
        guard let deadline=nextClickDeadline, now()>=deadline else { return [] }
        nextClickDeadline=nil; return [.play(.waving)]
    }
    @discardableResult public func cancel() -> Bool {
        let interruptedDrag=dragging
        origin=nil; dragging=false; doublePress=false; nextClickDeadline=nil
        return interruptedDrag
    }
}
public extension PetManifest {
    func resolve(_ requested: PetAction) -> PetAction {
        if animations[requested] != nil { return requested }
        if requested == .jumping && animations[.waving] != nil { return .waving }
        return .idle
    }
}
