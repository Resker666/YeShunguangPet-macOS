import AppKit
import PetCore

@MainActor final class ChatLocalVoiceSettingsView: NSStackView {
    private let controller: ChatController, hasBlockingModal: () -> Bool
    private let engine = NSTextField(wrappingLabelWithString: ""), role = NSTextField(wrappingLabelWithString: ""), status = NSTextField(wrappingLabelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let voices = NSPopUpButton()
    private let apply = NSButton(), importButton = NSButton(), confirmImport = NSButton(), cancel = NSButton(), delete = NSButton(), refresh = NSButton(), retry = NSButton(), reset = NSButton()
    private var panel: NSOpenPanel?
    private var renderedContext: ChatCharacter?, renderedEntries = [LocalVoiceLibraryEntry](), renderedBinding: UUID?
    init(controller: ChatController, hasBlockingModal: @escaping () -> Bool) {
        self.controller = controller; self.hasBlockingModal = hasBlockingModal
        super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 8
        let heading = NSTextField(labelWithString: "本地角色音色"); heading.font = .boldSystemFont(ofSize: 13)
        let help = NSTextField(wrappingLabelWithString: "首版使用本机独立引擎，仅支持已准备环境的 Apple Silicon Mac。导入只登记音色，不会启用语音、绑定角色或发声。请只导入可信来源的语音包；摘要只检查文件完整性，不证明来源。")
        configure(apply, "应用当前角色音色", #selector(applyPressed)); configure(importButton, "导入语音包…", #selector(importPressed))
        configure(confirmImport, "确认导入语音包", #selector(confirmPressed)); configure(cancel, "取消预览", #selector(cancelPressed))
        configure(delete, "删除选中语音包…", #selector(deletePressed)); configure(refresh, "刷新本地语音库", #selector(refreshPressed))
        configure(retry, "重试本地更改与清理", #selector(retryPressed)); configure(reset, "备份并重置语音库索引…", #selector(resetPressed))
        voices.target = self; voices.action = #selector(selectionChanged)
        voices.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voices.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voices.cell?.lineBreakMode = .byTruncatingTail
        for view in [heading, help, engine, role, voices, apply, importButton, previewLabel, confirmImport, cancel, delete, refresh, status, retry, reset] {
            addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
        for field in [help, engine, role, status, previewLabel] { field.font = .systemFont(ofSize: 12); field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        voices.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configure(_ button: NSButton, _ title: String, _ selector: Selector) { button.title = title; button.target = self; button.action = selector; button.bezelStyle = .rounded }
    private var allowed: Bool { !hasBlockingModal() && !controller.disposed && !controller.terminating && !controller.sleeping && controller.voice?.hasOutputActivity != true && controller.voice?.blocksChat != true }
    private var selectedID: UUID? { (voices.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)) }
    func render() {
        guard let model = controller.localVoices else { engine.stringValue = "本地语音服务尚未配置。"; return }
        switch model.engineStatus {
        case .unconfigured: engine.stringValue = "引擎未配置。请先按项目说明准备本机语音环境；App 不会自动安装依赖。"
        case .configured: engine.stringValue = "本机引擎已配置，首次朗读时才检查并加载。"
        case .unavailable(let message): engine.stringValue = message
        }
        let context = controller.character, binding = context.flatMap { model.index.binding(for: $0.id) }
        if renderedContext != context || renderedEntries != model.entries || renderedBinding != binding {
            let selection = renderedContext == context && renderedBinding == binding ? selectedID : binding
            renderedContext = context; renderedEntries = model.entries; renderedBinding = binding
            voices.removeAllItems(); voices.addItem(withTitle: "使用系统音色")
            voices.menu?.autoenablesItems = false
            for entry in model.entries {
                let suffix = String(entry.id.uuidString.prefix(8))
                voices.addItem(withTitle: suffix + " · " + entry.registration.name + (entry.issue == nil ? "" : "（文件不可用）"))
                voices.lastItem?.representedObject = entry.id.uuidString
                // Unusable packages remain selectable for safe deletion; the
                // independent Apply action rejects them.
                voices.lastItem?.toolTip = entry.issue.map { $0 + "；可选中后删除未绑定副本。" }
            }
            if let selection, let item = voices.itemArray.first(where: { ($0.representedObject as? String).flatMap(UUID.init(uuidString:)) == selection }) { voices.select(item) }
        }
        let boundName = binding.flatMap { id in model.index.packages.first { $0.id == id }?.name } ?? "系统音色"
        role.stringValue = context.map { "当前角色：\($0.name) · \($0.id)\n已应用：\(boundName)" } ?? "尚未选择角色。"
        let editable = allowed && model.isLoaded && !model.isBusy && !model.hasUnsaved
        let noPreview = model.preview == nil
        voices.isEnabled = editable && noPreview && model.protection == nil && context != nil
        let usableSelection = selectedID.map { id in model.entries.first { $0.id == id }?.issue == nil } ?? true
        apply.isEnabled = voices.isEnabled && usableSelection
        importButton.isEnabled = editable && model.protection == nil && model.preview == nil
        refresh.isEnabled = allowed && model.isLoaded && !model.isBusy
        delete.isEnabled = editable && noPreview && model.protection == nil && selectedID.map { !model.index.bindings.values.contains($0) } == true
        retry.isHidden = !model.hasUnsaved; retry.isEnabled = allowed && !model.isBusy
        reset.isHidden = model.protection == nil; reset.isEnabled = editable && noPreview
        let staged = model.preview
        previewLabel.stringValue = staged.map { "待导入：\($0.manifest.name)\nID：\($0.manifest.id) · 中文参考片段\n确认后仍需手动选择并应用当前角色音色。" } ?? ""
        previewLabel.isHidden = staged == nil; confirmImport.isHidden = staged == nil; cancel.isHidden = staged == nil
        confirmImport.isEnabled = editable && model.protection == nil; cancel.isEnabled = !controller.terminating && !controller.disposed
        status.stringValue = [model.protection, model.error, model.isBusy ? "正在处理本地语音资料…" : nil].compactMap { $0 }.joined(separator: "\n")
        status.isHidden = status.stringValue.isEmpty; status.textColor = model.error == nil && model.protection == nil ? .secondaryLabelColor : .systemRed
    }
    @objc private func applyPressed() {
        guard allowed, let expected = renderedContext, controller.character == expected else { return }
        controller.localVoices?.applyBinding(selectedID, expected: expected)
    }
    @objc private func selectionChanged() { render() }
    @objc private func importPressed() {
        guard allowed, panel == nil, let window else { return }
        let panel = NSOpenPanel(); self.panel = panel
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择包含 voice.json、s2.pth 和 reference.wav 的可信语音包文件夹。"; panel.prompt = "预览"
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }; self.panel = nil
                guard response == .OK, self.allowed, let url = panel.url else { return }
                self.controller.localVoices?.preview(folder: url)
            }
        }
    }
    @objc private func confirmPressed() { guard allowed else { return }; controller.localVoices?.confirmImport() }
    @objc private func cancelPressed() { controller.localVoices?.cancelPreview() }
    @objc private func refreshPressed() { guard allowed else { return }; controller.localVoices?.refresh() }
    @objc private func retryPressed() { guard allowed else { return }; controller.localVoices?.retryPendingSave() }
    @objc private func deletePressed() {
        guard allowed, let id = selectedID, let entry = controller.localVoices?.index.packages.first(where: { $0.id == id }) else { return }
        confirm("删除语音包？", "删除 \(entry.name)（\(id.uuidString.prefix(8))）的 App 内副本。仍被角色使用时不会删除；原导入文件夹不受影响。") { [weak self] in self?.controller.localVoices?.delete(id) }
    }
    @objc private func resetPressed() {
        guard allowed else { return }
        confirm("备份并重置语音库索引？", "仅备份并重置本地音色列表与角色绑定；保留语音包文件、聊天和语音偏好。") { [weak self] in self?.controller.localVoices?.backupAndReset() }
    }
    private func confirm(_ title: String, _ detail: String, action: @escaping @MainActor () -> Void) {
        guard let window, allowed else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in guard response == .alertFirstButtonReturn, self?.allowed == true else { return }; action() }
        }
    }
    func cancelPanel() { panel?.cancel(nil); panel = nil }
}
