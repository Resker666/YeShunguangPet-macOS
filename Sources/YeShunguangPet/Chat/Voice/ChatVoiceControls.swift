import AppKit

@MainActor final class ChatVoiceControls: NSStackView {
    private let controller: ChatController
    private let hasBlockingModal: () -> Bool, hasMarkedInput: () -> Bool
    private let selection: () -> NSRange, openSettings: () -> Void
    private let input = NSButton(), cancel = NSButton(), read = NSButton(), accept = NSButton(), online = NSButton()
    private let status = NSTextField(wrappingLabelWithString: ""), preview = NSTextField(wrappingLabelWithString: "")
    private let network = NSTextField(wrappingLabelWithString: "本机识别不可用。允许本次在线识别将开始一段新录音，录音可能交给 Apple 处理；现有预览会丢弃。")
    init(controller: ChatController, hasBlockingModal: @escaping () -> Bool, hasMarkedInput: @escaping () -> Bool, selection: @escaping () -> NSRange, openSettings: @escaping () -> Void) {
        self.controller = controller; self.hasBlockingModal = hasBlockingModal; self.hasMarkedInput = hasMarkedInput
        self.selection = selection; self.openSettings = openSettings
        super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 5
        configure(input, "开始说话", #selector(inputPressed)); configure(cancel, "取消录音", #selector(cancelPressed))
        configure(read, "朗读最近回复", #selector(readPressed)); configure(accept, "接受预览到草稿", #selector(acceptPressed)); configure(online, "允许本次在线识别", #selector(onlinePressed))
        let row = NSStackView(views: [input, cancel]); row.spacing = 5
        for view in [row, read, status, preview, accept, network, online] {
            addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
        for field in [status, preview, network] { field.font = .systemFont(ofSize: 12); field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var allowed: Bool { !hasBlockingModal() && !hasMarkedInput() && !controller.disposed && !controller.terminating }
    private func configure(_ button: NSButton, _ title: String, _ action: Selector) { button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded; button.controlSize = .small }
    func render() {
        let voice = controller.voice
        let enabled = voice?.settings.enabledForSession == true
        let state = voice?.captureState ?? .idle
        if !enabled { input.title = "语音设置…" }
        else if state == .recording { input.title = "结束识别" }
        else if state == .idle { input.title = voice?.preview.isEmpty == false ? "丢弃预览并重新录音" : "开始说话" }
        else { input.title = state == .finishing ? "等待最终识别…" : "准备录音…" }
        input.isEnabled = allowed && (!enabled || state == .recording || (state == .idle && controller.canPrepareVoiceInput))
        cancel.isHidden = state == .idle; cancel.isEnabled = allowed
        read.title = voice?.isStoppingOutput == true ? "确认停止中…" : voice?.outputStopFailed == true ? "重试停止朗读" : voice?.hasOutputActivity == true ? "停止朗读" : "朗读最近回复"
        read.isHidden = !enabled && voice?.isStoppingOutput != true && voice?.outputStopFailed != true
        read.isEnabled = allowed && voice?.blocksChat != true && voice?.isStoppingOutput != true && (voice?.hasOutputActivity == true || voice?.outputStopFailed == true || controller.conversation?.messages.contains(where: { $0.role == .assistant }) == true)
        let phase: String
        switch state {
        case .idle: phase = voice?.outputStatus ?? "主动录音，最长 45 秒；识别填入草稿后请手动发送。"
        case .stoppingOutput: phase = "正在确认语音输出已停止"
        case .requestingPermissions: phase = "正在检查麦克风与语音识别权限，可取消"
        case .recording: phase = "正在录音 · 最长 45 秒"
        case .finishing: phase = "正在等待最终识别 · 最多 5 秒"
        }
        status.stringValue = voice?.error ?? (enabled || voice?.isStoppingOutput == true ? phase : "语音默认关闭，可在语音设置中启用。")
        status.textColor = voice?.error == nil ? .secondaryLabelColor : .systemRed
        preview.stringValue = voice?.preview.isEmpty == false ? "识别预览（尚未发送）：\n" + (voice?.preview ?? "") : ""
        preview.isHidden = preview.stringValue.isEmpty
        accept.isHidden = preview.isHidden || state != .idle; accept.isEnabled = allowed && controller.canPrepareVoiceInput
        network.isHidden = voice?.canOfferNetwork != true; online.isHidden = network.isHidden
        online.isEnabled = allowed && controller.canPrepareVoiceInput && state == .idle
    }
    @objc private func inputPressed() {
        guard allowed else { return }
        guard let voice = controller.voice, voice.settings.enabledForSession else { openSettings(); return }
        if voice.captureState == .recording { voice.finishInput() }
        else if voice.captureState == .idle { voice.beginInput(selection: selection()) }
    }
    @objc private func cancelPressed() { guard allowed else { return }; controller.voice?.cancelInput() }
    @objc private func readPressed() {
        guard allowed, let voice = controller.voice else { return }
        if voice.hasOutputActivity || voice.outputStopFailed || voice.isStoppingOutput { voice.stop() }
        else if let text = controller.conversation?.messages.last(where: { $0.role == .assistant })?.content { voice.readLatest(text) }
    }
    @objc private func acceptPressed() { guard allowed else { return }; controller.voice?.acceptPreview() }
    @objc private func onlinePressed() { guard allowed else { return }; controller.voice?.allowNetworkForThisRecording(selection: selection()) }
}
