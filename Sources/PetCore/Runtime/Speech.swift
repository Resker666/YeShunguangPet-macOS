import Foundation

public enum SpeechEvent:String,CaseIterable,Sendable { case click,drag,focusCompleted,breakCompleted }
public struct SpeechPolicy {
    private let random:()->Double
    private var lastShown:Duration?
    private var lastLine:String?
    public init(random:@escaping ()->Double = {Double.random(in:0..<1)}) {self.random=random}
    public mutating func select(lines:SpeechLines?,event:SpeechEvent,at now:Duration)->String? {
        if event == .click || event == .drag,let lastShown,now-lastShown < .seconds(30) {return nil}
        let choices=(lines ?? .defaults).lines(for:event)
        guard !choices.isEmpty else{return nil}
        let alternatives=choices.filter{$0 != lastLine},available=alternatives.isEmpty ? choices : alternatives
        let draw=random(),unit=draw.isFinite ? min(max(draw,0),1.nextDown) : 0
        let line=available[Int(unit*Double(available.count))]
        lastShown=now;lastLine=line;return line
    }
}
public enum SpeechPlacement {
    public static func place(anchor:CGRect,size:CGSize,area:CGRect)->CGRect? {
        guard [anchor.minX,anchor.minY,anchor.width,anchor.height,size.width,size.height,area.minX,area.minY,area.width,area.height].allSatisfy({$0.isFinite}),
              anchor.width>0,anchor.height>0,size.width>0,size.height>0,size.width<=area.width,size.height<=area.height else{return nil}
        let x=min(max(anchor.midX-size.width/2,area.minX),area.maxX-size.width)
        let y=min(max(anchor.midY-size.height/2,area.minY),area.maxY-size.height)
        let candidates=[CGRect(x:x,y:anchor.maxY+8,width:size.width,height:size.height),
                        CGRect(x:x,y:anchor.minY-size.height-8,width:size.width,height:size.height),
                        CGRect(x:anchor.maxX+8,y:y,width:size.width,height:size.height),
                        CGRect(x:anchor.minX-size.width-8,y:y,width:size.width,height:size.height)]
        return candidates.first{area.contains($0) && !$0.intersects(anchor)}
    }
}
