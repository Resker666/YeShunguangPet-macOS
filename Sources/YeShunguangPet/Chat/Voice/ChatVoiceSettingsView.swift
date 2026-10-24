import AppKit
import PetCore

@MainActor final class ChatVoiceSettingsView: NSStackView {
    private let controller: ChatController, hasBlockingModal: () -> Bool, onResetRequested: () -> Void
    private let enabled = NSButton(checkboxWithTitle: "启用语音输入与朗读", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "自动朗读新回复（仅首次成功保存的普通回复）", target: nil, action: nil)
    private let voices = NSPopUpButton(), rate = NSSlider(value: 0.5, minValue: 0.35, maxValue: 0.65, target: nil, action: nil)
    private let apply = NSButton(), disable = NSButton(), preview = NSButton(), stop = NSButton(), retry = NSButton(), discard = NSButton(), reset = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rendered: VoicePreferences?, renderedVoices = [SystemVoice]()
    init(controller: ChatController, hasBlockingModal: @escaping () -> Bool, onResetRequested: @escaping () -> Void) {
        self.controller = controller; self.hasBlockingModal = hasBlockingModal; self.onResetRequested = onResetRequested
        super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 10
        configure(apply, "应用语音设置", #selector(applyPressed)); configure(disable, "立即关闭语音", #selector(disablePressed))
        configure(preview, "试听已应用音色", #selector(previewPressed)); configure(stop, "停止朗读", #selector(stopPressed))
        configure(retry, "重试本地保存", #selector(retryPressed)); configure(discard, "放弃待存设置", #selector(discardPressed)); configure(reset, "备份并重置语音设置…", #selector(resetPressed))
        let help = NSTextField(wrappingLabelWithString: "语音默认关闭。启用或打开本页不会录音、发声或申请权限；点击录音后才检查权限。优先本机中文识别，联网只在提示后由你允许本次新录音。识别文字可编辑并由你手动发送，DeepSeek 不接收录音。\n自动朗读长回复只读开头，最多 600 个 UTF-16 单元。安静模式、隐藏、菜单及阻挡窗口期间不朗读，不补读。这里只提供已安装的 Apple 中文音色；缺失时可在系统设置的辅助功能／朗读内容中下载。")
        let voiceLabel = NSTextField(labelWithString: "首选音色（保存缺失选择时会使用可用的中文回退音色）")
        let rateLabel = NSTextField(labelWithString: "语速 · 0.35 慢 — 0.65 快（默认 0.5）")
        for view in [help, enabled, automatic, voiceLabel, voices, rateLabel, rate, apply, disable, preview, stop, status, retry, discard, reset] {
            addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
        for field in [help, status] { field.font = .systemFont(ofSize: 12); field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        voices.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        rate.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var allowed: Bool { !hasBlockingModal() && !controller.disposed && !controller.terminating && !controller.sleeping }
    private func configure(_ button: NSButton, _ title: String, _ action: Selector) { button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded }
    func render() {
        guard let voice = controller.voice else { status.stringValue = "语音服务尚未配置。"; return }
        let settings = voice.settings, value = settings.preferences
        if rendered != value || renderedVoices != voice.availableVoices {
            rendered = value; renderedVoices = voice.availableVoices
            enabled.state = value.enabled ? .on : .off; automatic.state = value.automaticReadAloud ? .on : .off; rate.doubleValue = value.rate
            voices.removeAllItems(); voices.addItem(withTitle: "自动选择中文音色")
            for item in voice.availableVoices { voices.addItem(withTitle: item.name + " · " + item.language); voices.lastItem?.representedObject = item.id }
            if let id = value.voiceIdentifier {
                if !voice.availableVoices.contains(where: { $0.id == id }) { voices.addItem(withTitle: "已保存的音色当前不可用"); voices.lastItem?.representedObject = id }
                if let index = voices.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { voices.selectItem(at: index) }
            }
        }
        let editable = allowed && settings.isLoaded && !settings.isWriting && settings.protection == nil && !voice.blocksChat
        for view in [enabled, automatic, voices, rate, apply] as [NSControl] { view.isEnabled = editable }
        disable.isEnabled = allowed && settings.isLoaded
        preview.isEnabled = allowed && settings.enabledForSession && !voice.blocksChat
        stop.isEnabled = allowed && voice.isSpeaking
        retry.isHidden = !settings.hasUnsaved; discard.isHidden = !settings.hasUnsaved
        retry.isEnabled = allowed && !settings.isWriting; discard.isEnabled = retry.isEnabled
        reset.isHidden = settings.protection == nil; reset.isEnabled = allowed && !settings.isWriting
        let actual = voice.actualVoice.map { "实际使用：\($0.name) · \($0.language)" }
        status.stringValue = [settings.protection, settings.error, voice.error, actual, settings.isWriting ? "正在保存语音设置" : settings.enabledForSession ? "本次语音已启用" : "本次语音已关闭"].compactMap { $0 }.joined(separator: "\n")
        status.textColor = settings.error == nil && settings.protection == nil && voice.error == nil ? .secondaryLabelColor : .systemRed
    }
    @objc private func applyPressed() {
        guard allowed, let voice = controller.voice, !voice.blocksChat else { return }
        voice.settings.apply(.init(enabled: enabled.state == .on, automaticReadAloud: automatic.state == .on, voiceIdentifier: voices.selectedItem?.representedObject as? String, rate: rate.doubleValue))
    }
    @objc private func disablePressed() { guard allowed else { return }; controller.voice?.settings.disable() }
    @objc private func previewPressed() { guard allowed else { return }; controller.voice?.previewVoice() }
    @objc private func stopPressed() { guard allowed else { return }; controller.voice?.stop() }
    @objc private func retryPressed() { guard allowed else { return }; controller.voice?.settings.retryPendingSave() }
    @objc private func discardPressed() { guard allowed else { return }; controller.voice?.settings.discardPendingSave() }
    @objc private func resetPressed() { guard allowed else { return }; onResetRequested() }
}
