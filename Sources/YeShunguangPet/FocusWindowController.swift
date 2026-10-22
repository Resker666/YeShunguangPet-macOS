import AppKit
import Combine
import PetCore

@MainActor final class FocusPanel:NSPanel {
    var onRequestClose:(()->Void)?
    init() {
        super.init(contentRect:CGRect(x:0,y:0,width:280,height:208),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        title="专注计时";setAccessibilityLabel("桌面专注计时器")
        isOpaque=false;backgroundColor = .clear;hasShadow=true;hidesOnDeactivate=false
        isReleasedWhenClosed=false;isMovableByWindowBackground=false;animationBehavior = .none
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
    }
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
    override func performClose(_ sender:Any?) {onRequestClose?()}
}
@MainActor private final class FocusDragHeader:NSView {
    var onDragFinished:(()->Void)?
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {
        guard let hit=super.hitTest(point) else{return nil}
        var ancestor:NSView?=hit
        while let view=ancestor,view !== self {if view is NSButton{return hit};ancestor=view.superview}
        return self
    }
    override func mouseDown(with event:NSEvent) {
        guard event.type == .leftMouseDown else{return}
        window?.performDrag(with:event);onDragFinished?()
    }
}
@MainActor private final class FocusWindowButton:NSButton {
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
}
@MainActor private final class FocusWindowBackground:NSView {
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:14,yRadius:14)
        NSColor.windowBackgroundColor.setFill();path.fill()
        NSColor.separatorColor.setStroke();path.lineWidth=1;path.stroke()
    }
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}

@MainActor final class FocusWindowController:NSObject,NSWindowDelegate {
    let panel=FocusPanel()
    let timeLabel=NSTextField(labelWithString:"")
    let statusLabel=NSTextField(labelWithString:"")
    private(set) var primaryButton=FocusWindowButton(title:"",target:nil,action:nil) as NSButton
    private let resetButton=FocusWindowButton(title:"重置",target:nil,action:nil)
    private let pinButton=FocusWindowButton(),closeButton=FocusWindowButton(),retryButton=FocusWindowButton(title:"重试",target:nil,action:nil)
    private let hint=NSTextField(labelWithString:"每段结束后，手动开始下一段")
    private let progress=NSProgressIndicator()
    private let buttons=NSStackView()
    private let session:PetSession,focus:FocusController
    private let canDispatch:()->Bool
    private var subscription:AnyCancellable?
    private var started=false,disposed=false,terminating=false,saving=false
    private var lastStored:FocusWindowPreferences?
    private(set) var configuration=FocusWindowPreferences()
    private(set) var lastSaveError:String?
    var onPresentationChange:(()->Void)?
    init(session:PetSession,focus:FocusController,canDispatch:@escaping ()->Bool) {
        self.session=session;self.focus=focus;self.canDispatch=canDispatch
        super.init();buildContent();panel.delegate=self
        panel.onRequestClose={[weak self] in self?.setVisible(false)}
        subscription=focus.$snapshot.sink{[weak self] snapshot in self?.refreshControls(snapshot)}
        for name in [NSApplication.didHideNotification,NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self,selector:#selector(appVisibilityChanged),name:name,object:nil)
        }
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
    }
    private var canOperate:Bool {!disposed && !terminating && !session.gate.exiting && canDispatch()}
    func start(){guard !started,!disposed else{return};started=true;refreshPreferences()}
    func refreshPreferences() {
        guard started,!disposed,!saving else{return}
        let stored=session.preferences.focusWindow
        if stored != lastStored {lastStored=stored;configuration=stored;placeRestored();applyPresentation()}
        refreshControls()
    }
    private func initialPlacement()->PlacementSnapshot? {
        let screens=session.screens()
        guard let screen=screens.first(where:{$0.isPrimary}) ?? screens.first else{return nil}
        return WindowPlacement.capture(origin:CGPoint(x:screen.visibleFrame.maxX-panel.frame.width-24,y:screen.visibleFrame.maxY-panel.frame.height-24),size:panel.frame.size,screens:[screen])
    }
    private func placeRestored() {
        let areas=session.screens(),saved=configuration.placement
        let restored=saved.flatMap{old in areas.contains(where:{$0.id==old.screenID}) ? WindowPlacement.restore(old,size:panel.frame.size,screens:areas) : nil} ?? initialPlacement()
        if let restored {configuration.placement=restored;panel.setFrameOrigin(restored.origin)}
    }
    private func applyPresentation() {
        panel.level=configuration.alwaysOnTop ? .floating : .normal
        if configuration.isVisible {if !NSApp.isHidden{panel.orderFrontRegardless()}}else{panel.orderOut(nil)}
        updateDisplayVisibility();refreshControls();onPresentationChange?()
    }
    func setVisible(_ visible:Bool) {
        guard canOperate else{return};configuration.isVisible=visible
        applyPresentation();persist();focus.refreshTime()
    }
    func setAlwaysOnTop(_ pinned:Bool) {
        guard canOperate else{return};configuration.alwaysOnTop=pinned;applyPresentation();persist()
    }
    func recall() {
        guard canOperate else{return}
        if let placement=initialPlacement(){configuration.placement=placement;panel.setFrameOrigin(placement.origin)}
        configuration.isVisible=true;applyPresentation();persist();focus.refreshTime()
    }
    func finishDrag() {
        guard canOperate,let captured=WindowPlacement.capture(origin:panel.frame.origin,size:panel.frame.size,screens:session.screens()) else{return}
        configuration.placement=captured;panel.setFrameOrigin(captured.origin);persist()
    }
    func screenChanged() {
        guard started,!disposed,!terminating,!session.gate.exiting else{return}
        let previous=configuration.placement;placeRestored()
        if configuration.placement != previous{persist()}
    }
    private func persist() {
        guard !disposed,!terminating else{return}
        saving=true;defer{saving=false;refreshControls();onPresentationChange?()}
        do {try session.saveFocusWindow(configuration);lastStored=session.preferences.focusWindow;lastSaveError=nil}
        catch {lastSaveError=error.localizedDescription}
    }
    @objc func retrySave(){guard canOperate else{return};persist()}
    private func updateDisplayVisibility(){focus.setDisplayVisible(started && !disposed && !terminating && panel.isVisible && !NSApp.isHidden,source:"desktop-window")}
    @objc private func appVisibilityChanged(){guard started,!disposed else{return};applyPresentation()}
    @objc private func screensChanged(){screenChanged()}
    func beginTermination(){terminating=true;updateDisplayVisibility();refreshControls()}
    func cancelTermination(){guard !disposed else{return};terminating=false;applyPresentation();focus.refreshTime()}
    func dispose() {
        guard !disposed else{return};disposed=true;subscription=nil
        NotificationCenter.default.removeObserver(self);updateDisplayVisibility()
        panel.onRequestClose=nil;panel.delegate=nil;panel.close();onPresentationChange=nil
    }
    private func refreshControls(_ published:FocusSnapshot?=nil) {
        guard !disposed else{return}
        // @Published emits before storage changes: render the incoming value.
        let snapshot=published ?? focus.snapshot
        let command=FocusCommand(kind:snapshot.status == .running ? .pause : .startOrResume,generation:focus.primaryCommand.generation)
        timeLabel.stringValue=snapshot.timeText;statusLabel.stringValue=snapshot.statusText
        progress.doubleValue=Double(max(0,snapshot.durationSeconds-snapshot.remainingSeconds))/Double(max(1,snapshot.durationSeconds))
        if primaryButton.cell?.representedObject as? FocusCommand != command {
            buttons.removeArrangedSubview(primaryButton);primaryButton.removeFromSuperview()
            let next=FocusWindowButton(title:snapshot.primaryTitle,target:self,action:#selector(primary(_:)))
            next.bezelStyle = .rounded;next.bezelColor = .controlAccentColor;next.cell?.representedObject=command
            primaryButton=next;buttons.insertArrangedSubview(next,at:0)
        }
        primaryButton.isEnabled=canOperate;resetButton.isEnabled=canOperate && snapshot.status != .ready
        pinButton.image=NSImage(systemSymbolName:configuration.alwaysOnTop ? "pin.fill" : "pin",accessibilityDescription:"计时器置顶")
        pinButton.state=configuration.alwaysOnTop ? .on : .off;pinButton.isEnabled=canOperate;closeButton.isEnabled=canOperate
        hint.stringValue=lastSaveError == nil ? "每段结束后，手动开始下一段" : "窗口偏好未保存"
        hint.toolTip=lastSaveError;retryButton.isHidden=lastSaveError == nil;retryButton.isEnabled=canOperate
    }
    @objc private func primary(_ sender:NSButton){guard canOperate,let command=sender.cell?.representedObject as? FocusCommand else{return};focus.perform(command)}
    @objc private func reset(){guard canOperate else{return};focus.reset()}
    @objc private func pin(){setAlwaysOnTop(!configuration.alwaysOnTop)}
    @objc private func hide(){setVisible(false)}
    private func buildContent() {
        let background=FocusWindowBackground(frame:CGRect(origin:.zero,size:panel.frame.size));panel.contentView=background
        let header=FocusDragHeader();header.translatesAutoresizingMaskIntoConstraints=false
        header.onDragFinished={[weak self] in self?.finishDrag()};header.toolTip="拖动顶部移动计时器"
        let title=NSTextField(labelWithString:"专注计时");title.font = .systemFont(ofSize:12,weight:.medium);title.textColor = .secondaryLabelColor
        closeButton.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:"隐藏计时器");closeButton.toolTip="隐藏计时器，计时继续";closeButton.target=self;closeButton.action=#selector(hide)
        pinButton.toolTip="切换计时器置顶";pinButton.target=self;pinButton.action=#selector(pin)
        for view in [closeButton,title,pinButton]{view.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(view)}
        for button in [closeButton,pinButton]{button.isBordered=false}
        background.addSubview(header)
        timeLabel.font = .monospacedDigitSystemFont(ofSize:46,weight:.medium);timeLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize:13,weight:.medium);statusLabel.alignment = .center;statusLabel.textColor = .secondaryLabelColor
        progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;progress.style = .bar
        buttons.orientation = .horizontal;buttons.distribution = .fillEqually;buttons.spacing=8
        resetButton.bezelStyle = .rounded;resetButton.target=self;resetButton.action=#selector(reset)
        buttons.addArrangedSubview(primaryButton);buttons.addArrangedSubview(resetButton)
        hint.font = .systemFont(ofSize:10);hint.textColor = .secondaryLabelColor;retryButton.bezelStyle = .inline;retryButton.font = .systemFont(ofSize:11);retryButton.target=self;retryButton.action=#selector(retrySave)
        let footer=NSStackView(views:[hint,retryButton]);footer.orientation = .horizontal;footer.spacing=5;footer.alignment = .centerY
        let stack=NSStackView(views:[statusLabel,timeLabel,progress,buttons,footer]);stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=7;stack.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(stack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:8),header.trailingAnchor.constraint(equalTo:background.trailingAnchor,constant:-8),header.topAnchor.constraint(equalTo:background.topAnchor,constant:5),header.heightAnchor.constraint(equalToConstant:28),
            closeButton.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:4),closeButton.centerYAnchor.constraint(equalTo:header.centerYAnchor),closeButton.widthAnchor.constraint(equalToConstant:24),
            pinButton.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-4),pinButton.centerYAnchor.constraint(equalTo:header.centerYAnchor),pinButton.widthAnchor.constraint(equalToConstant:24),
            title.centerXAnchor.constraint(equalTo:header.centerXAnchor),title.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            stack.topAnchor.constraint(equalTo:header.bottomAnchor,constant:2),stack.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:background.trailingAnchor,constant:-18),stack.bottomAnchor.constraint(lessThanOrEqualTo:background.bottomAnchor,constant:-10),
            progress.widthAnchor.constraint(equalTo:stack.widthAnchor),buttons.widthAnchor.constraint(equalTo:stack.widthAnchor),buttons.heightAnchor.constraint(equalToConstant:30)
        ])
        refreshControls()
    }
}
