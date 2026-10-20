import AppKit

@MainActor final class PetPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect:CGRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isOpaque=false; backgroundColor = .clear; hasShadow=false
        hidesOnDeactivate=false; level = .floating; isReleasedWhenClosed=false
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        animationBehavior = .none; isMovableByWindowBackground=false
        title="叶瞬光桌宠"; setAccessibilityLabel("桌面角色")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
