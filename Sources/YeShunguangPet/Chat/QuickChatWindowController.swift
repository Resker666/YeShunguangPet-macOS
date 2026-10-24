import AppKit
import Combine
import PetCore

@MainActor private final class QuickChatBody: NSStackView { override var isFlipped: Bool { true } }

@MainActor final class QuickChatWindowController: NSWindowController, NSWindowDelegate, ChatPresentationHosting {
    let controller: ChatController
    let composer = ChatComposer(), transcript = NSTextView()
    let bodyScroll = NSScrollView()
    private let body = QuickChatBody()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton(), stopButton = NSButton(), expandButton = NSButton(), retryButton = NSButton()
    private var actionCard: ChatActionCardView!
    private var voiceControls: ChatVoiceControls!
    var onVoiceSettings: (() -> Void)?
    var canPresent: Bool { allowed && !hasMarkedInput }
    var voiceSurface: ChatVoiceSurface { .conversation }
    private var transcriptHeight: NSLayoutConstraint!
    private weak var session: PetSession?
    private let onExpand: () -> Void, canDispatch: () -> Bool
    private var onClose: (() -> Void)?, onVisibility: (() -> Void)?
    private var observation: AnyCancellable?
    private var terminating = false, disposed = false, rendering = false, scheduledRender = false, positioning = false
    var hasBlockingSheet: Bool { window?.attachedSheet != nil || NSApp.modalWindow != nil }
    var hasMarkedInput: Bool { composer.hasMarkedText() || (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    var isPresentationVisible: Bool { !disposed && window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden }
    var inputSelection: NSRange {
        get { composer.selectedRange() }
        set { composer.setSelectedRange(ChatInputSelection.clamped(newValue, in: composer.string)) }
    }
    init(controller: ChatController, session: PetSession, onExpand: @escaping () -> Void, canDispatch: @escaping () -> Bool) {
        self.controller = controller; self.session = session; self.onExpand = onExpand; self.canDispatch = canDispatch
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isMovable = false
        window.contentMinSize = .init(width: 320, height: 240)
        super.init(window: window); window.delegate = self
        actionCard = ChatActionCardView(controller: controller, hasBlockingModal: { [weak self] in
            guard let self else { return true }; return !self.allowed || self.hasMarkedInput
        })
        voiceControls = ChatVoiceControls(controller: controller, hasBlockingModal: { [weak self] in self?.allowed != true }, hasMarkedInput: { [weak self] in self?.hasMarkedInput != false }, selection: { [weak self] in self?.inputSelection ?? .init(location: 0, length: 0) }, openSettings: { [weak self] in self?.onVoiceSettings?() })
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 6
        root.edgeInsets = .init(top: 10, left: 10, bottom: 10, right: 10); root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        bodyScroll.drawsBackground = false; bodyScroll.hasVerticalScroller = true
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8; body.edgeInsets = .init(top: 0, left: 0, bottom: 8, right: 10)
        body.translatesAutoresizingMaskIntoConstraints = false; bodyScroll.documentView = body
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor), body.heightAnchor.constraint(greaterThanOrEqualTo: bodyScroll.contentView.heightAnchor)])
        for field in [transcript, composer] {
            field.isRichText = false; field.importsGraphics = false; field.isAutomaticLinkDetectionEnabled = false; field.isAutomaticTextReplacementEnabled = false
            field.font = .systemFont(ofSize: 13); field.textColor = .textColor; field.backgroundColor = .textBackgroundColor
            field.textContainerInset = .init(width: 5, height: 5); field.isHorizontallyResizable = false; field.isVerticallyResizable = true
            field.textContainer?.widthTracksTextView = true; field.autoresizingMask = [.width]
        }
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcriptHeight = transcript.heightAnchor.constraint(equalToConstant: 80); transcriptHeight.isActive = true
        configure(retryButton, "重试本地保存", #selector(retry))
        for view in [transcript, status, actionCard!, voiceControls!, retryButton] {
            body.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -10).isActive = true
        }
        status.font = .systemFont(ofSize: 12)
        let input = NSScrollView(); input.hasVerticalScroller = true; input.borderType = .bezelBorder; input.documentView = composer
        composer.minSize = .init(width: 0, height: 50); composer.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.heightAnchor.constraint(equalToConstant: 50).isActive = true
        configure(sendButton, "发送 ⌘↩", #selector(send)); configure(stopButton, "停止", #selector(stop)); configure(expandButton, "展开完整聊天", #selector(expand))
        let row = NSStackView(views: [sendButton, stopButton, expandButton]); row.orientation = .horizontal; row.spacing = 6
        for view in [bodyScroll, input, row] {
            root.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true
        }
        bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        composer.onSend = { [weak self] in self?.send() }
        composer.onTextChange = { [weak self] text in
            guard let self, !self.rendering else { return }; self.controller.setDraft(text)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] { center.addObserver(self, selector: #selector(anchorChanged), name: name, object: session.panel) }
        center.addObserver(self, selector: #selector(anchorChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] { center.addObserver(self, selector: #selector(appVisibilityChanged), name: name, object: nil) }
        observation = controller.objectWillChange.sink { [weak self] in
            guard let self, !self.scheduledRender else { return }; self.scheduledRender = true
            DispatchQueue.main.async { [weak self] in self?.scheduledRender = false; self?.render() }
        }
        render(); reposition()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var allowed: Bool { !disposed && !terminating && !hasBlockingSheet && canDispatch() }
    private func configure(_ button: NSButton, _ title: String, _ action: Selector) { button.title = title; button.bezelStyle = .rounded; button.target = self; button.action = action }
    private func sentences(_ text: String) -> String {
        text.replacingOccurrences(of: "([。！？!?]|\\.(?=\\s|$))(?!\\n)", with: "$1\n", options: .regularExpression)
    }
    func render() {
        guard !disposed, !rendering else { return }; rendering = true; defer { rendering = false }
        let offset = bodyScroll.contentView.bounds.minY
        let nearBottom = bodyScroll.contentView.bounds.maxY >= body.bounds.maxY - 30
        window?.title = "轻聊天 · \(controller.character?.name ?? "正在载入")"
        let recent = Array((controller.conversation?.messages ?? []).suffix(2))
        var text = recent.map { ($0.role == .user ? "你" : controller.character?.name ?? "角色") + "：\n" + sentences($0.content) }.joined(separator: "\n\n")
        if let input = controller.currentProvisionalInput { text += "\n\n你（本次）：\n" + input }
        if !controller.partialReply.isEmpty {
            let phase = controller.isGeneratingConversation ? "生成中" : controller.state == .unsaved ? "完整但尚未保存" : "未完成，不计入历史"
            text += "\n\n本次回复（\(phase)）：\n" + sentences(controller.partialReply)
        }
        if text.isEmpty { text = "输入文字与角色聊天。操作提议需你确认后才执行。" }
        if transcript.string != text { transcript.string = text }
        if composer.string != controller.draft && !composer.hasMarkedText() { composer.string = controller.draft }
        if isPresentationVisible, !hasMarkedInput, let selection = controller.takeVoiceSelection() { inputSelection = selection }
        let phase: String
        switch controller.state {
        case .loading: phase = "正在读取本地资料"
        case .readingCredential: phase = "正在读取钥匙串"
        case .streaming: phase = "正在回复"
        case .extractingMemories: phase = "正在提炼记忆"
        case .awaitingAction: phase = "请确认或取消操作提议"
        case .saving: phase = "正在保存本地资料"
        case .unsaved: phase = "完整回复或操作回执尚未保存"
        case .unsavedMemory: phase = "记忆变更尚未保存，请展开处理"
        case .failed: phase = "请展开完整聊天检查设置"
        case .idle: phase = controller.connection.enabled ? "Enter 换行 · ⌘Enter 发送" : "AI 已关闭，请展开配置"
        }
        status.stringValue = controller.error ?? phase; status.textColor = controller.error == nil ? .secondaryLabelColor : .systemRed
        actionCard.render(); voiceControls.render()
        sendButton.isEnabled = allowed && !hasMarkedInput && controller.canSend
        stopButton.isEnabled = allowed && (controller.isGenerating || controller.voice?.hasActivity == true)
        expandButton.isEnabled = allowed && !hasMarkedInput
        retryButton.isHidden = !controller.canRetryPendingSave; retryButton.isEnabled = allowed && controller.canRetryPendingSave
        composer.isEditable = !terminating && controller.voice?.blocksChat != true && controller.state != .unsaved && controller.state != .saving
        window?.contentView?.layoutSubtreeIfNeeded()
        transcript.textContainer?.containerSize = .init(width: max(1, transcript.bounds.width - 10), height: CGFloat.greatestFiniteMagnitude)
        if let layout = transcript.layoutManager, let container = transcript.textContainer {
            layout.ensureLayout(for: container)
            transcriptHeight.constant = max(80, ceil(layout.usedRect(for: container).height) + 12)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        let limit = max(0, body.bounds.height - bodyScroll.contentSize.height)
        bodyScroll.contentView.scroll(to: .init(x: 0, y: nearBottom ? limit : min(offset, limit)))
        bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
    }
    func reposition() {
        guard !disposed, !positioning, let session, let window else { return }
        positioning = true; defer { positioning = false }
        guard let frame = QuickChatPlacement.frame(anchor: session.panel.frame, size: window.frame.size, screens: session.screens()) else { return }
        if window.frame != frame { window.setFrame(frame, display: window.isVisible) }
    }
    @objc private func anchorChanged(_ notification: Notification) { reposition() }
    @objc private func appVisibilityChanged(_ notification: Notification) { onVisibility?() }
    func windowDidResize(_ notification: Notification) { render(); reposition() }
    func windowDidMiniaturize(_ notification: Notification) { onVisibility?() }
    func windowDidDeminiaturize(_ notification: Notification) { onVisibility?() }
    func windowDidEndSheet(_ notification: Notification) { render() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowed && !hasMarkedInput }
    func windowWillClose(_ notification: Notification) { if let onClose { onClose() } else { controller.windowClosed() } }
    override func cancelOperation(_ sender: Any?) { guard allowed, !hasMarkedInput else { return }; if let onClose { onClose() } else { close() } }
    func setPresentationCallbacks(onClose: @escaping () -> Void, onVisibility: @escaping () -> Void) { self.onClose = onClose; self.onVisibility = onVisibility }
    @discardableResult func presentForHandoff(selection: NSRange) -> Bool {
        guard canPresent else { return false }
        render(); inputSelection = selection; reposition()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window?.makeFirstResponder(composer); onVisibility?()
        return window?.isVisible == true
    }
    func hideForHandoff() { window?.orderOut(nil); onVisibility?() }
    func resetLogicalDrafts() { /* The shared input draft survives logical close. */ }
    func beginTermination() { terminating = true; render() }
    func cancelTermination() { terminating = false; render() }
    func dispose() {
        guard !disposed else { return }; disposed = true; observation = nil
        NotificationCenter.default.removeObserver(self); window?.delegate = nil; window?.orderOut(nil)
    }
    @objc private func send() { guard allowed, !hasMarkedInput else { return }; controller.send() }
    @objc private func stop() { guard allowed else { return }; controller.stop() }
    @objc private func expand() { guard allowed, !hasMarkedInput else { return }; onExpand() }
    @objc private func retry() { guard allowed else { return }; controller.retryPendingSave() }
}
