import Foundation
import CoreGraphics

public struct ScreenArea: Equatable {
    public let id: String, visibleFrame: CGRect, isPrimary: Bool
    public init(id: String, visibleFrame: CGRect, isPrimary: Bool) { self.id=id; self.visibleFrame=visibleFrame; self.isPrimary=isPrimary }
}
public struct PlacementSnapshot: Codable, Equatable {
    public let screenID: String, origin: CGPoint, visibleFrame: CGRect
    public init(screenID: String, origin: CGPoint, visibleFrame: CGRect) { self.screenID=screenID; self.origin=origin; self.visibleFrame=visibleFrame }
    enum CodingKeys: String,CodingKey { case screenID,x,y,visibleX,visibleY,visibleWidth,visibleHeight }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        screenID=try c.decode(String.self,forKey:.screenID)
        origin=try CGPoint(x:c.decode(Double.self,forKey:.x),y:c.decode(Double.self,forKey:.y))
        visibleFrame=try CGRect(x:c.decode(Double.self,forKey:.visibleX),y:c.decode(Double.self,forKey:.visibleY),width:c.decode(Double.self,forKey:.visibleWidth),height:c.decode(Double.self,forKey:.visibleHeight))
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(screenID,forKey:.screenID); try c.encode(origin.x,forKey:.x); try c.encode(origin.y,forKey:.y)
        try c.encode(visibleFrame.minX,forKey:.visibleX); try c.encode(visibleFrame.minY,forKey:.visibleY)
        try c.encode(visibleFrame.width,forKey:.visibleWidth); try c.encode(visibleFrame.height,forKey:.visibleHeight)
    }
    var isValid: Bool { !screenID.isEmpty && screenID.utf16.count<=128 && origin.x.isFinite && origin.y.isFinite && WindowPlacement.valid(visibleFrame) }
}
public enum WindowPlacement {
    static func valid(_ rect: CGRect) -> Bool { [rect.origin.x,rect.origin.y,rect.width,rect.height].allSatisfy{$0.isFinite} && rect.width>0 && rect.height>0 }
    private static func usable(_ screens: [ScreenArea], _ size: CGSize) -> [ScreenArea] {
        guard size.width.isFinite,size.height.isFinite,size.width>0,size.height>0 else { return [] }
        return screens.filter{!$0.id.isEmpty && valid($0.visibleFrame)}
    }
    private static func snapshot(_ point: CGPoint, size: CGSize, screen: ScreenArea) -> PlacementSnapshot {
        let r=screen.visibleFrame
        let origin=CGPoint(x:min(max(r.minX,point.x),max(r.minX,r.maxX-size.width)),y:min(max(r.minY,point.y),max(r.minY,r.maxY-size.height)))
        return .init(screenID:screen.id,origin:origin,visibleFrame:r)
    }
    public static func recall(size: CGSize, screens: [ScreenArea]) -> PlacementSnapshot? {
        let screens=usable(screens,size)
        guard let screen=screens.first(where:{$0.isPrimary}) ?? screens.first else { return nil }
        return snapshot(CGPoint(x:screen.visibleFrame.maxX-size.width-24,y:screen.visibleFrame.minY+24),size:size,screen:screen)
    }
    public static func restore(_ saved: PlacementSnapshot?, size: CGSize, screens: [ScreenArea]) -> PlacementSnapshot? {
        let screens=usable(screens,size)
        guard let saved,saved.isValid,let screen=screens.first(where:{$0.id==saved.screenID}) else { return recall(size:size,screens:screens) }
        if screen.visibleFrame==saved.visibleFrame { return snapshot(saved.origin,size:size,screen:screen) }
        func ratio(_ origin: CGFloat,_ minimum: CGFloat,_ length: CGFloat,_ cell: CGFloat) -> CGFloat { length>cell ? min(1,max(0,(origin-minimum)/(length-cell))) : 0 }
        let old=saved.visibleFrame, new=screen.visibleFrame
        return snapshot(CGPoint(x:new.minX+ratio(saved.origin.x,old.minX,old.width,size.width)*max(0,new.width-size.width),y:new.minY+ratio(saved.origin.y,old.minY,old.height,size.height)*max(0,new.height-size.height)),size:size,screen:screen)
    }
    public static func capture(origin: CGPoint, size: CGSize, screens: [ScreenArea],snapToEdges:Bool=false) -> PlacementSnapshot? {
        guard origin.x.isFinite,origin.y.isFinite else { return nil }
        let screens=usable(screens,size), frame=CGRect(origin:origin,size:size)
        func area(_ screen: ScreenArea) -> CGFloat { let r=frame.intersection(screen.visibleFrame); return r.isNull ? 0 : r.width*r.height }
        func distance(_ screen: ScreenArea) -> CGFloat { let r=screen.visibleFrame; let dx=max(r.minX-frame.midX,0,frame.midX-r.maxX), dy=max(r.minY-frame.midY,0,frame.midY-r.maxY); return dx*dx+dy*dy }
        guard let best=screens.max(by:{ area($0)==area($1) ? distance($0)>distance($1) : area($0)<area($1) }) else { return nil }
        let captured=snapshot(origin,size:size,screen:best)
        guard snapToEdges else{return captured}
        func snapped(_ value:CGFloat,lower:CGFloat,upper:CGFloat)->CGFloat {
            let upper=max(lower,upper)
            if value-lower<=12 && value-lower<=upper-value{return lower}
            if upper-value<=12{return upper}
            return value
        }
        let area=best.visibleFrame
        return PlacementSnapshot(screenID:captured.screenID,origin:CGPoint(x:snapped(captured.origin.x,lower:area.minX,upper:area.maxX-size.width),y:snapped(captured.origin.y,lower:area.minY,upper:area.maxY-size.height)),visibleFrame:area)
    }
}
