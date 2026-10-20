import AppKit

@MainActor final class PetView: NSView {
    var image: CGImage? { didSet { rendered=image.map { NSImage(cgImage:$0,size:bounds.size) }; needsDisplay=true } }
    private var rendered: NSImage?
    var onDown: ((CGPoint,Int)->Void)?, onMove: ((CGPoint)->Void)?, onUp: ((CGPoint)->Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using:.copy)
        rendered?.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    override func mouseDown(with event: NSEvent) { onDown?(NSEvent.mouseLocation,event.clickCount) }
    override func mouseDragged(with event: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onUp?(NSEvent.mouseLocation) }
}
