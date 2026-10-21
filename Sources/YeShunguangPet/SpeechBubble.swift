import AppKit
import PetCore

@MainActor private final class BubbleBackground:NSView {
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10)
        NSColor.windowBackgroundColor.setFill();path.fill()
        NSColor.separatorColor.setStroke();path.lineWidth=1;path.stroke()
    }
}

@MainActor final class SpeechBubble {
    let panel=PetPanel(size:.zero)
    private let label=NSTextField(wrappingLabelWithString:"")
    init() {
        panel.title="角色台词";panel.setAccessibilityLabel("角色台词");panel.ignoresMouseEvents=true
        let background=BubbleBackground(frame:.zero)
        label.font=NSFont.systemFont(ofSize:13);label.textColor = .labelColor;label.isSelectable=false
        label.maximumNumberOfLines=0;background.addSubview(label);panel.contentView=background
    }
    func show(_ text:String,owner:NSWindow,area:CGRect)->Bool {
        let width=min(276,area.width-16)
        guard width>32 else{return false}
        let font=label.font ?? NSFont.systemFont(ofSize:13)
        let measured=(text as NSString).boundingRect(with:CGSize(width:width-24,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font])
        let size=CGSize(width:width,height:max(18,ceil(measured.height)+4)+20)
        guard let frame=SpeechPlacement.place(anchor:owner.frame,size:size,area:area) else{return false}
        dismiss();label.stringValue=text
        panel.setFrame(frame,display:false);panel.contentView?.setFrameSize(size)
        label.frame=CGRect(x:12,y:10,width:size.width-24,height:size.height-20)
        panel.level=owner.level;owner.addChildWindow(panel,ordered:.above);panel.orderFrontRegardless()
        return true
    }
    func dismiss() {panel.parent?.removeChildWindow(panel);panel.orderOut(nil)}
    func close() {dismiss();panel.close()}
}
