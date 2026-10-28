import AppKit
import PetCore

@MainActor final class ChatLocalVoiceEngineView: NSStackView {
    private let controller:ChatController, hasBlockingModal:()->Bool
    private let current = NSTextField(wrappingLabelWithString:""), detail = NSTextField(wrappingLabelWithString:""), status = NSTextField(wrappingLabelWithString:"")
    private let install = NSButton(), check = NSButton(), confirm = NSButton(), cancelPreview = NSButton(), cancel = NSButton(), retry = NSButton()
    private let meter = NSProgressIndicator()
    private var panel:NSOpenPanel?
    init(controller:ChatController,hasBlockingModal:@escaping()->Bool) {
        self.controller = controller; self.hasBlockingModal = hasBlockingModal
        super.init(frame:.zero);orientation = .vertical;alignment = .leading;spacing = 8
        let heading = NSTextField(labelWithString:"本地语音引擎");heading.font = .boldSystemFont(ofSize:13)
        let help = NSTextField(wrappingLabelWithString:"引擎与角色音色分开安装。打开独立引擎 DMG 后选择其中的引擎文件夹，无需另装 Python；安装本身不会启用语音、绑定角色或发声。引擎包含可执行代码，请只选择可信来源；摘要校验不能证明来源。")
        configure(install,"安装或修复本地引擎…",#selector(installPressed));configure(check,"检查当前引擎",#selector(checkPressed))
        configure(confirm,"确认安装引擎",#selector(confirmPressed));configure(cancelPreview,"取消引擎预览",#selector(previewCancelled))
        configure(cancel,"取消引擎安装",#selector(cancelPressed));configure(retry,"重试引擎切换或清理",#selector(retryPressed))
        meter.isIndeterminate = false;meter.minValue = 0;meter.maxValue = 1;meter.style = .bar
        for view in [heading,help,current,install,check,detail,confirm,cancelPreview,meter,status,cancel,retry] {
            addArrangedSubview(view);view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor).isActive = true
        }
        for field in [help,current,detail,status] { field.font = .systemFont(ofSize:12);field.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
        meter.widthAnchor.constraint(equalTo:widthAnchor).isActive = true;render()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configure(_ button:NSButton,_ title:String,_ selector:Selector) { button.title = title;button.target = self;button.action = selector;button.bezelStyle = .rounded }
    private var allowed:Bool { !hasBlockingModal() && !controller.disposed && !controller.terminating && !controller.sleeping }
    func render() {
        guard let model = controller.localEngine else {
            current.stringValue = "引擎安装服务尚未配置。";for b in [install,check,confirm,cancelPreview,cancel,retry] { b.isEnabled = false };detail.isHidden = true;meter.isHidden = true;return
        }
        if !model.isSupported { current.stringValue = "本地引擎首版仅支持 M 系列 Mac。此 Mac 可继续使用文字聊天和系统音色。" }
        else {
            switch model.snapshot.status {
            case .unconfigured:current.stringValue = "当前引擎：尚未安装。"
            case .configured:current.stringValue = "当前引擎：" + (model.snapshot.packageName ?? "旧版本机环境") + model.snapshot.packageVersion.map { " · \($0)" }.orEmpty
            case .unavailable(let message):current.stringValue = "当前引擎不可用：\(message)"
            }
        }
        let preview = model.preview
        install.isEnabled = allowed && model.canBegin && preview == nil
        check.isEnabled = install.isEnabled
        detail.stringValue = preview.map { "待安装：\($0.manifest.name)\n版本：\($0.manifest.version) · " + ByteCountFormatter.string(fromByteCount:Int64($0.manifest.totalBytes),countStyle:.file) + "\n确认后开始复制、自检，成功后才切换。旧引擎会保留。" } ?? ""
        detail.isHidden = preview == nil;confirm.isHidden = preview == nil;cancelPreview.isHidden = preview == nil
        confirm.isEnabled = allowed && model.canBegin;cancelPreview.isEnabled = allowed
        meter.isHidden = ![.copying,.verifying].contains(model.phase)
        if let progress = model.progress, progress.totalBytes > 0 { meter.doubleValue = Double(progress.completedBytes)/Double(progress.totalBytes) }
        let stage:String
        switch model.phase {
        case .idle:stage = ""
        case .previewing:stage = "正在读取引擎包清单…"
        case .awaitingConfirmation:stage = "请核对后确认安装。"
        case .stopping:stage = "正在停止语音输出…"
        case .copying:stage = "正在复制引擎…"
        case .verifying:stage = "正在校验引擎副本…"
        case .probing:stage = "正在离线自检，首次可能需要较长时间…"
        case .activating:stage = "正在保存并切换引擎…"
        case .installed:stage = "引擎已就绪。角色音色仍在下方单独导入与应用。"
        case .checking:stage = "正在检查当前引擎…"
        case .cancelling:stage = "正在取消并清理本次资源…"
        case .failed:stage = "本次操作未完成，旧引擎保持。"
        }
        let bytes = !meter.isHidden ? model.progress.map { "\($0.completedBytes) / \($0.totalBytes) 字节" } : nil
        status.stringValue = [stage,bytes,model.error].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:"\n")
        status.isHidden = status.stringValue.isEmpty;status.textColor = model.error == nil ? .secondaryLabelColor : .systemRed
        cancel.isHidden = !(model.isBusy && model.phase != .previewing) && !model.hasUnsaved
        cancel.isEnabled = allowed && model.phase != .cancelling
        retry.isHidden = !model.hasUnsaved && !model.hasPendingResources
        retry.isEnabled = allowed && model.canRetry
    }
    @objc private func installPressed() {
        guard allowed, controller.localEngine?.canBegin == true, panel == nil, let window else { return }
        let panel = NSOpenPanel();self.panel = panel
        panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.allowsMultipleSelection = false
        panel.message = "选择独立引擎 DMG 中含 engine.json 和 payload 的可信引擎文件夹。";panel.prompt = "预览引擎"
        panel.beginSheetModal(for:window) { [weak self] answer in
            Task { @MainActor in
                guard let self, self.panel === panel else { return };self.panel = nil
                guard answer == .OK, self.allowed, let url = panel.url else { return };self.controller.localEngine?.preview(folder:url)
            }
        }
    }
    @objc private func checkPressed() { guard allowed else { return };controller.localEngine?.checkCurrent() }
    @objc private func confirmPressed() { guard allowed else { return };controller.localEngine?.confirmInstall() }
    @objc private func previewCancelled() { controller.localEngine?.cancelPreview() }
    @objc private func cancelPressed() { guard allowed else { return };controller.localEngine?.cancelInstallation() }
    @objc private func retryPressed() { guard allowed else { return };controller.localEngine?.retryPending() }
    func cancelPanel() { panel?.cancel(nil);panel = nil;controller.localEngine?.cancelPreview() }
}
private extension Optional where Wrapped == String { var orEmpty:String { self ?? "" } }
