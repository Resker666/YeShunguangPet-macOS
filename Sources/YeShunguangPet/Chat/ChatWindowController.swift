import AppKit
import Combine
import PetCore

@MainActor final class ChatWindowController: NSWindowController, NSWindowDelegate {
    let controller: ChatController
    let pages = NSSegmentedControl(labels:["对话","人设","连接"],trackingMode:.selectOne,target:nil,action:nil)
    let pageScroll = NSScrollView()
    let transcript = NSTextView()
    let composer = ChatComposer()
    private let content = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString:"")
    private let sendButton = NSButton(), stopButton = NSButton(), copyButton = NSButton(), clearButton = NSButton()
    private let retryButton = NSButton(), discardButton = NSButton(), resetButton = NSButton()
    private let applyProfileButton = NSButton()
    private let profileFields = (0..<4).map { _ in NSTextView() }
    private let enabled = NSButton(checkboxWithTitle:"开启 AI 聊天",target:nil,action:nil)
    private let model = NSPopUpButton()
    private let applyConnectionButton = NSButton(), retryConnectionButton = NSButton(), resetConnectionButton = NSButton()
    private let key = NSSecureTextField()
    private let saveKeyButton = NSButton(), removeKeyButton = NSButton()
    private let connectionLabel = NSTextField(wrappingLabelWithString:"")
    private let onPresentationChange: (Bool) -> Void
    private let copyText: (String) -> Bool
    private var observation: AnyCancellable?
    private var renderedContext: ChatCharacter?, profileRevision: UInt64?, credentialRevision: UInt64 = 0
    private var renderedConnection: ChatConnection?
    private var page = 0, scheduledRender = false, rendering = false, terminating = false, disposed = false
    private var editorContext: ChatCharacter?
    var hasBlockingSheet: Bool { window?.attachedSheet != nil || NSApp.modalWindow != nil }

    init(controller: ChatController, onPresentationChange: @escaping (Bool) -> Void, copyText: ((String) -> Bool)? = nil) {
        self.controller = controller; self.onPresentationChange = onPresentationChange
        self.copyText = copyText ?? { text in NSPasteboard.general.clearContents(); return NSPasteboard.general.setString(text,forType:.string) }
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:520,height:620),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.contentMinSize = CGSize(width:440,height:420)
        window.isReleasedWhenClosed = false
        super.init(window:window)
        window.delegate = self; window.center()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView(); window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)
        ])
        pages.target = self; pages.action = #selector(pageChanged); pages.selectedSegment = 0
        root.addArrangedSubview(pages)
        statusLabel.font = .systemFont(ofSize:12); statusLabel.setContentCompressionResistancePriority(.required,for:.vertical)
        root.addArrangedSubview(statusLabel)
        pageScroll.hasVerticalScroller = true; pageScroll.drawsBackground = false
        root.addArrangedSubview(pageScroll)
        pageScroll.translatesAutoresizingMaskIntoConstraints = false
        pageScroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-32).isActive = true
        statusLabel.widthAnchor.constraint(equalTo:pageScroll.widthAnchor).isActive = true
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top:0,left:0,bottom:16,right:12)
        content.translatesAutoresizingMaskIntoConstraints = false
        pageScroll.documentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo:pageScroll.contentView.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo:pageScroll.contentView.heightAnchor)
        ])
        prepareText(transcript); transcript.isEditable = false; transcript.isSelectable = true
        prepareText(composer); composer.onSend = { [weak self] in self?.send() }
        composer.onTextChange = { [weak self] text in guard let self, !self.rendering else { return }; self.controller.setDraft(text) }
        for field in profileFields { prepareText(field) }
        configure(sendButton,"发送 ⌘↩",#selector(send))
        configure(stopButton,"停止",#selector(stop))
        configure(copyButton,"复制回复",#selector(copyReply))
        configure(clearButton,"清空记录…",#selector(clear))
        configure(retryButton,"重试本地保存",#selector(retry))
        configure(discardButton,"丢弃待存问答…",#selector(discard))
        configure(resetButton,"备份并重置角色资料…",#selector(resetRole))
        configure(applyProfileButton,"应用人设",#selector(applyProfile))
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        model.addItems(withTitles:ChatModel.allCases.map(\.rawValue))
        configure(applyConnectionButton,"保存连接偏好",#selector(applyConnection))
        configure(retryConnectionButton,"重试连接偏好保存",#selector(retryConnection))
        configure(resetConnectionButton,"备份并重置连接资料…",#selector(resetConnection))
        key.placeholderString = "粘贴 API 密钥；不会回显已保存的密钥"
        configure(saveKeyButton,"保存密钥到钥匙串",#selector(saveKey))
        configure(removeKeyButton,"移除密钥…",#selector(removeKey))
        connectionLabel.font = .systemFont(ofSize:12)
        for name in [NSApplication.didHideNotification,NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self,selector:#selector(appVisibilityChanged),name:name,object:nil)
        }
        observation = controller.objectWillChange.sink { [weak self] in
            // Published emits before the mutation; render once after the main actor turn.
            guard let self, !self.scheduledRender else { return }
            self.scheduledRender = true
            DispatchQueue.main.async { [weak self] in self?.scheduledRender = false; self?.render() }
        }
        rebuildPage(); render()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func prepareText(_ view:NSTextView) {
        view.isRichText = false; view.importsGraphics = false
        view.font = .systemFont(ofSize:14); view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainerInset = CGSize(width:8,height:8)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
    }
    private func configure(_ button:NSButton,_ title:String,_ action:Selector) {
        button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    private func label(_ value:String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString:value); field.font = .systemFont(ofSize:12); return field
    }
    private func add(_ view:NSView) {
        content.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo:content.widthAnchor,constant:-12).isActive = true
    }
    private func textBox(_ view:NSTextView,height:CGFloat) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = view; scroll.heightAnchor.constraint(equalToConstant:height).isActive = true
        view.minSize = CGSize(width:0,height:height); view.maxSize = CGSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        return scroll
    }
    private func row(_ controls:NSView...) -> NSStackView {
        let stack = NSStackView(views:controls); stack.orientation = .horizontal; stack.spacing = 8; return stack
    }
    private func rebuildPage() {
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        switch page {
        case 0:
            add(textBox(transcript,height:240))
            add(label("输入最多 2000 个 UTF-16 单元。Enter 换行，⌘Enter 发送。"))
            add(textBox(composer,height:76))
            add(row(sendButton,stopButton,copyButton))
            add(clearButton); add(row(retryButton,discardButton)); add(resetButton)
        case 1:
            add(label("用户自定义的角色演绎。应用成功后生效；离开此页会丢弃未应用的编辑。"))
            for (index,title) in ["背景 · 2000","性格 · 1000","说话风格 · 1000","示例台词 · 2000"].enumerated() {
                add(label(title)); add(textBox(profileFields[index],height:84))
            }
            add(applyProfileButton)
        default:
            add(label("DeepSeek 官方接口 · https://api.deepseek.com"))
            add(enabled); add(label("模型")); add(model); add(applyConnectionButton); add(retryConnectionButton)
            add(label("API 密钥")); add(key); add(row(saveKeyButton,removeKeyButton)); add(connectionLabel)
            add(label("仅点击发送才会联网，将当前人设、最近 12 轮完整对话和本次文字交给 DeepSeek，按你的 API 账户计费。打开窗口或保存设置不会发送测试请求。"))
            add(label("密钥保存在 macOS 钥匙串；连接偏好单独保存。关闭 AI 会立即停止当前请求，取消不能撤回服务商已经收到的内容。"))
            add(resetConnectionButton)
        }
        content.layoutSubtreeIfNeeded()
    }
    func selectPage(_ value:Int) {
        guard (0..<3).contains(value) else { return }
        if page == 1 || value == 1 { reloadProfile() }
        page = value; pages.selectedSegment = value; rebuildPage(); render()
    }
    @objc private func pageChanged() { selectPage(pages.selectedSegment) }
    private func reloadProfile() {
        let profile = controller.conversation?.profile ?? ChatProfile()
        for (field,value) in zip(profileFields,[profile.background,profile.personality,profile.speakingStyle,profile.examples]) { field.string = value }
        editorContext = controller.character
    }
    func render() {
        guard !disposed else { return }
        rendering = true; defer { rendering = false }
        let context = controller.character
        window?.title = "聊天 · \(context?.name ?? "正在载入")"
        if renderedContext != context || profileRevision != controller.profileEditRevision {
            renderedContext = context; profileRevision = controller.profileEditRevision; reloadProfile()
        }
        if renderedConnection != controller.connection {
            renderedConnection = controller.connection
            enabled.state = controller.connection.enabled ? .on : .off
            model.selectItem(at:ChatModel.allCases.firstIndex(of:controller.connection.model) ?? 0)
        }
        if credentialRevision != controller.credentialSavedRevision { credentialRevision = controller.credentialSavedRevision; key.stringValue = "" }
        let messages = controller.conversation?.messages ?? []
        var text = messages.map { ($0.role == .user ? "你" : context?.name ?? "角色") + "：\n" + $0.content }.joined(separator:"\n\n")
        if let input=controller.currentProvisionalInput { text += "\n\n你（本次）：\n" + input }
        if !controller.partialReply.isEmpty {
            text += "\n\n本次回复（\(controller.state == .unsaved ? "完整但尚未保存" : controller.isGenerating ? "生成中" : "未完成，不计入历史")）：\n" + controller.partialReply
        }
        let oldSelection = transcript.selectedRange()
        if transcript.string != text {
            let nearBottom = transcript.enclosingScrollView.map { $0.contentView.bounds.maxY >= transcript.bounds.maxY - 30 } ?? true
            transcript.string = text
            transcript.setSelectedRange(NSRange(location:min(oldSelection.location,text.utf16.count),length:0))
            if nearBottom { transcript.scrollToEndOfDocument(nil) }
        }
        if composer.string != controller.draft { composer.string = controller.draft }
        let phase: String
        switch controller.state {
        case .loading: phase = "正在读取本地资料"
        case .readingCredential: phase = "正在读取钥匙串"
        case .streaming: phase = "正在回复"
        case .saving: phase = "正在保存本地资料"
        case .unsaved: phase = "完整回复尚未保存"
        case .failed: phase = "需要处理"
        case .idle: phase = controller.connection.enabled ? "就绪" : "AI 已关闭，请在连接页配置"
        }
        statusLabel.stringValue = "\(context?.name ?? "") · \(context?.id ?? "")\n" + (controller.error ?? phase)
        statusLabel.textColor = controller.error == nil ? .secondaryLabelColor : .systemRed
        sendButton.isEnabled = !terminating && !hasBlockingSheet && !composer.hasMarkedText() && controller.canSend
        stopButton.isEnabled = !terminating && controller.isGenerating
        copyButton.isEnabled = !terminating && (!controller.partialReply.isEmpty || messages.last != nil)
        clearButton.isEnabled = !terminating && controller.canClearHistory
        retryButton.isHidden = !controller.canRetryPendingSave; discardButton.isHidden = retryButton.isHidden
        resetButton.isHidden = controller.currentArchiveProtection == nil
        resetButton.isEnabled = !terminating && !controller.hasPendingWrites
        composer.isEditable = !terminating && !controller.isGenerating && controller.state != .unsaved && controller.state != .saving
        applyProfileButton.isEnabled = !terminating && controller.canEditProfile
        for field in profileFields { field.isEditable = !terminating && controller.canEditProfile }
        enabled.isEnabled = !terminating && controller.connectionLoaded && (controller.connection.enabled || controller.canChangeConnection)
        model.isEnabled = !terminating && controller.canChangeConnection
        applyConnectionButton.isEnabled = !terminating && controller.canChangeConnection && controller.connectionProtection == nil
        retryConnectionButton.isHidden = !controller.canRetryConnectionSave
        saveKeyButton.isEnabled = !terminating && controller.canChangeConnection
        removeKeyButton.isEnabled = saveKeyButton.isEnabled; key.isEnabled = saveKeyButton.isEnabled
        resetConnectionButton.isHidden = controller.connectionProtection == nil
        resetConnectionButton.isEnabled = !terminating && controller.canChangeConnection
        connectionLabel.stringValue = [controller.connectionProtection,controller.connectionError,controller.credentialMutationError,controller.credentialFeedback].compactMap{$0}.joined(separator:"\n")
    }
    func present() {
        guard !disposed, !terminating, !hasBlockingSheet else { return }
        render(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); updatePresentation()
    }
    private func updatePresentation() {
        let visible = !disposed && window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden
        controller.setPresented(visible); onPresentationChange(visible)
    }
    @objc private func appVisibilityChanged(_ notification:Notification) { updatePresentation() }
    func windowDidMiniaturize(_ notification:Notification) { updatePresentation() }
    func windowDidDeminiaturize(_ notification:Notification) { updatePresentation() }
    func windowDidEndSheet(_ notification:Notification) { render() }
    func windowWillClose(_ notification:Notification) {
        controller.windowClosed(); key.stringValue = ""; reloadProfile()
        controller.setPresented(false); onPresentationChange(false)
    }
    func beginTermination() { terminating = true; render() }
    func cancelTermination() { terminating = false; render() }
    func dispose() {
        guard !disposed else { return }; disposed = true; observation = nil
        NotificationCenter.default.removeObserver(self)
        window?.delegate = nil; window?.orderOut(nil); onPresentationChange(false); controller.setPresented(false)
        key.stringValue = ""
    }
    @objc private func send() { guard !terminating, !hasBlockingSheet, !composer.hasMarkedText() else { return }; controller.send() }
    @objc private func stop() { controller.stop() }
    @objc func copyReply() {
        guard !terminating, !hasBlockingSheet else { return }
        let text = controller.partialReply.isEmpty ? controller.conversation?.messages.last?.content ?? "" : controller.partialReply
        if !text.isEmpty, !copyText(text) { statusLabel.stringValue = "复制失败，请重试。" }
    }
    private func confirm(_ title:String,_ detail:String,perform:() -> Void) {
        guard !terminating, !hasBlockingSheet else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle:"确认"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn, !terminating { perform() }
        render()
    }
    @objc private func clear() {
        guard let context = controller.character else { return }
        confirm("清空当前角色的本机记录？","保留人设。成功清空也会丢弃完整待存问答；不会删除服务商已经收到的数据。") { controller.clearHistory(for:context) }
    }
    @objc private func retry() { controller.retryPendingSave() }
    @objc private func discard() {
        let context = controller.character
        confirm("丢弃尚未保存的完整问答？","原历史保留，输入仍可编辑。") { if controller.character == context { controller.discardPendingSave() } }
    }
    @objc private func resetRole() {
        let context = controller.character
        confirm("备份并重置角色资料？","原文件先保留备份，然后重置此角色人设与历史。") { if controller.character == context { controller.resetCharacterArchive() } }
    }
    @objc private func applyProfile() {
        guard let context = editorContext else { return }
        controller.applyProfile(.init(background:profileFields[0].string,personality:profileFields[1].string,speakingStyle:profileFields[2].string,examples:profileFields[3].string),for:context)
    }
    @objc private func toggleEnabled() {
        // Turning off is immediate even while a reply is in flight.
        controller.saveConnection(.init(enabled:enabled.state == .on,model:controller.connection.model))
    }
    @objc private func applyConnection() {
        guard ChatModel.allCases.indices.contains(model.indexOfSelectedItem) else { return }
        controller.saveConnection(.init(enabled:enabled.state == .on,model:ChatModel.allCases[model.indexOfSelectedItem]))
    }
    @objc private func retryConnection() { controller.retryConnectionSave() }
    @objc private func saveKey() { controller.saveCredential(key.stringValue) }
    @objc private func removeKey() { confirm("移除本 App 的 API 密钥？","人设和历史仍保留，下一次发送前需重新保存密钥。") { controller.removeCredential() } }
    @objc private func resetConnection() { confirm("备份并重置连接资料？","恢复 AI 关闭和默认模型；不会移除钥匙串密钥。") { controller.resetConnectionArchive() } }
}
