import AppKit
import PetCore

@MainActor final class ChatMemoryView: NSStackView {
    private let controller: ChatController
    private let hasBlockingModal: () -> Bool
    private let confirm: (String, String, @escaping () -> Void) -> Void
    private let countLabel = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView(), editorSection = NSStackView(), candidates = NSStackView()
    private let editor = ChatComposer()
    private let extractButton = NSButton(), stopButton = NSButton(), clearButton = NSButton()
    private let saveEdit = NSButton(), retryButton = NSButton(), discardChange = NSButton()
    private let acceptButton = NSButton(), discardReview = NSButton()
    private var context: ChatCharacter?, revision: UInt64 = 0, editRevision: UInt64?
    private var editingID: UUID?, editorContext: ChatCharacter?, editorRevision: UInt64 = 0
    private var reviewID: UUID?
    private var candidateFields = [UUID: ChatComposer](), checks = [UUID: NSButton]()
    private var mutationButtons = [NSButton]()

    init(controller: ChatController, hasBlockingModal: @escaping () -> Bool, confirm: @escaping (String, String, @escaping () -> Void) -> Void) {
        self.controller = controller; self.hasBlockingModal = hasBlockingModal; self.confirm = confirm
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        for section in [list, editorSection, candidates] { section.orientation = .vertical; section.alignment = .leading; section.spacing = 8 }
        add(countLabel)
        add(label("每个角色最多 20 条，每条最多 200 个 UTF-16 单元。已确认记忆随后续聊天发送，重开保留。"))
        configure(clearButton, "清除全部记忆…", #selector(clearAll)); add(clearButton)
        add(list)
        add(editorSection)
        add(label("编辑记忆"), to: editorSection)
        editor.identifier = .init("memory-editor")
        add(textArea(editor), to: editorSection)
        configure(saveEdit, "保存修改", #selector(saveEditor))
        let cancelEdit = NSButton(); configure(cancelEdit, "取消编辑", #selector(cancelEditor))
        add(row(saveEdit, cancelEdit), to: editorSection)
        editor.onTextChange = { [weak self] _ in DispatchQueue.main.async { [weak self] in self?.render() } }
        configure(retryButton, "重试本地保存", #selector(retry))
        configure(discardChange, "放弃本次变更…", #selector(discardPending))
        add(row(retryButton, discardChange)); add(feedback)
        configure(extractButton, "提炼记忆", #selector(extract))
        configure(stopButton, "停止提炼", #selector(stop))
        add(row(extractButton, stopButton))
        add(label("点击提炼会额外调用 DeepSeek，发送当前角色已保存的最近 12 轮问答及已有记忆，按你的 API 账户计费。至少需要一轮完整记录。"))
        add(label("先查看来源、修改并勾选，再保存。候选与未保存编辑仅在本次窗口保留；关闭窗口或换肤会丢弃。再次提炼前请先丢弃旧候选。"))
        add(candidates)
        configure(acceptButton, "保存所选", #selector(accept))
        configure(discardReview, "丢弃候选", #selector(discardCandidates))
        add(row(acceptButton, discardReview))
        add(label("清空聊天历史会保留记忆。删除记忆只停止发送该独立条目；若人设或最近对话仍含同文，模型仍可能看到。不会删除服务商已收到的数据。"))
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text); value.font = .systemFont(ofSize: 12)
        return value
    }
    private func add(_ view: NSView, to section: NSStackView? = nil) {
        let stack = section ?? self
        stack.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    private func row(_ controls: NSView...) -> NSStackView {
        let stack = NSStackView(views: controls); stack.orientation = .horizontal; stack.spacing = 8
        return stack
    }
    private func textArea(_ field: ChatComposer) -> NSScrollView {
        field.isRichText = false; field.importsGraphics = false; field.isAutomaticLinkDetectionEnabled = false
        field.isAutomaticTextReplacementEnabled = false; field.font = .systemFont(ofSize: 14)
        field.textColor = .textColor; field.backgroundColor = .textBackgroundColor
        field.textContainerInset = .init(width: 8, height: 8)
        field.isHorizontallyResizable = false; field.isVerticallyResizable = true
        field.autoresizingMask = [.width]; field.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = field; scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        return scroll
    }
    private func empty(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    func resetDrafts() {
        editingID = nil; editorContext = nil; editor.string = ""; editorSection.isHidden = true
    }
    private func rebuildList() {
        empty(list); mutationButtons = []
        let memories = controller.conversation?.memories ?? []
        if memories.isEmpty { add(label("还没有长期记忆，角色目前参考最近 12 轮对话。"), to: list) }
        for memory in memories {
            let text = label(memory.text); text.font = .systemFont(ofSize: 13)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let edit = NSButton(), delete = NSButton()
            configure(edit, "编辑", #selector(editMemory(_:))); configure(delete, "删除", #selector(deleteMemory(_:)))
            edit.identifier = .init(memory.id.uuidString); delete.identifier = edit.identifier
            mutationButtons += [edit, delete]
            add(row(text, edit, delete), to: list)
        }
    }
    private func rebuildCandidates(_ review: MemoryReviewState?) {
        empty(candidates); candidateFields = [:]; checks = [:]
        guard let review else { return }
        add(label(review.candidates.isEmpty ? "本次没有可新增的记忆。" : "来源为提炼时保存的最近 \(review.snapshot.rounds.count) 轮；之后的聊天不会改变这些依据。"), to: candidates)
        if review.duplicateCount > 0 { add(label("已略过 \(review.duplicateCount) 条完全重复的候选。"), to: candidates) }
        for candidate in review.candidates {
            let check = NSButton(checkboxWithTitle: "保存此条", target: self, action: #selector(selectCandidate(_:)))
            check.identifier = .init(candidate.id.uuidString); checks[candidate.id] = check; add(check, to: candidates)
            let field = ChatComposer(); field.identifier = .init("memory-candidate-" + candidate.id.uuidString)
            field.string = review.editedTexts[candidate.id] ?? candidate.text
            field.onTextChange = { [weak self] text in
                guard let self else { return }
                self.controller.setMemoryCandidateText(id: candidate.id, text: text)
                DispatchQueue.main.async { [weak self] in self?.render() }
            }
            candidateFields[candidate.id] = field; add(textArea(field), to: candidates)
            let source = label(review.snapshot.rounds.filter { candidate.sourceRounds.contains($0.number) }.map { "第 \($0.number) 轮 · 你：\n\($0.user)" }.joined(separator: "\n\n"))
            source.isHidden = true
            let toggle = MemorySourceButton(source: source)
            add(toggle, to: candidates); add(source, to: candidates)
        }
    }
    func render() {
        if context != controller.character || editRevision != controller.memoryEditRevision {
            context = controller.character; editRevision = controller.memoryEditRevision
            revision = controller.conversation?.memoryRevision ?? 0
            resetDrafts(); rebuildList()
        }
        if reviewID != controller.memoryReview?.id {
            reviewID = controller.memoryReview?.id; rebuildCandidates(controller.memoryReview)
        }
        let count = controller.conversation?.memories.count ?? 0
        countLabel.stringValue = "已保存记忆 · \(count)/20"
        let allowed = !hasBlockingModal() && controller.canEditMemories
        for button in mutationButtons { button.isEnabled = allowed }
        clearButton.isEnabled = allowed && count > 0
        editorSection.isHidden = editingID == nil
        editor.isEditable = allowed
        saveEdit.isEnabled = allowed && editingID != nil && !editor.hasMarkedText()
        extractButton.isEnabled = !hasBlockingModal() && controller.canExtractMemories
        stopButton.isHidden = !controller.isExtractingMemories
        stopButton.isEnabled = !hasBlockingModal() && controller.isExtractingMemories
        retryButton.isHidden = !controller.canRetryMemorySave; discardChange.isHidden = retryButton.isHidden
        retryButton.isEnabled = !hasBlockingModal() && controller.canRetryMemorySave
        discardChange.isEnabled = retryButton.isEnabled
        feedback.stringValue = controller.error ?? (count == 20 ? "记忆已满，请先编辑或删除已有条目。" : "")
        feedback.textColor = controller.error == nil ? .secondaryLabelColor : .systemRed
        let review = controller.memoryReview
        for (id, check) in checks { check.state = review?.selectedIDs.contains(id) == true ? .on : .off; check.isEnabled = allowed }
        for field in candidateFields.values { field.isEditable = allowed }
        acceptButton.isHidden = review == nil; discardReview.isHidden = review == nil
        acceptButton.isEnabled = allowed && review?.selectedIDs.isEmpty == false && !candidateFields.values.contains { $0.hasMarkedText() }
        discardReview.isEnabled = !hasBlockingModal() && !controller.isGenerating && !controller.sleeping && !controller.terminating
    }
    @objc private func editMemory(_ sender: NSButton) {
        guard !hasBlockingModal(), controller.canEditMemories, controller.character == context,
              let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let memory = controller.conversation?.memories.first(where: { $0.id == id }) else { return }
        editingID = id; editorContext = context; editorRevision = revision; editor.string = memory.text; render()
    }
    @objc private func saveEditor() {
        guard !hasBlockingModal(), !editor.hasMarkedText(), controller.canEditMemories,
              let id = editingID, let editorContext else { return }
        controller.saveMemory(id: id, text: editor.string, for: editorContext, expectedRevision: editorRevision)
    }
    @objc private func cancelEditor() { resetDrafts(); render() }
    @objc private func deleteMemory(_ sender: NSButton) {
        guard !hasBlockingModal(), controller.canEditMemories, let context, controller.character == context,
              let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        let revision = revision
        confirm("删除这条长期记忆？", "保留人设与聊天历史；历史中的同文仍可能提供给模型。") { [weak self] in
            guard let self, !self.hasBlockingModal() else { return }
            self.controller.deleteMemory(id: id, for: context, expectedRevision: revision)
        }
    }
    @objc private func clearAll() {
        guard !hasBlockingModal(), controller.canEditMemories, let context else { return }
        let revision = revision
        confirm("清除当前角色的全部长期记忆？", "保留人设和聊天历史，不删除服务商已经收到的数据。") { [weak self] in
            guard let self, !self.hasBlockingModal() else { return }
            self.controller.clearMemories(for: context, expectedRevision: revision)
        }
    }
    @objc private func extract() { guard !hasBlockingModal() else { return }; controller.extractMemories() }
    @objc private func stop() { guard !hasBlockingModal() else { return }; controller.stop() }
    @objc private func selectCandidate(_ sender: NSButton) {
        guard !hasBlockingModal(), let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        controller.setMemoryCandidateSelected(id: id, selected: sender.state == .on); render()
    }
    @objc private func accept() {
        guard !hasBlockingModal(), controller.canEditMemories, !candidateFields.values.contains(where: { $0.hasMarkedText() }), let review = controller.memoryReview else { return }
        for (id, field) in candidateFields { controller.setMemoryCandidateText(id: id, text: field.string) }
        controller.saveSelectedMemories(reviewID: review.id, for: review.context)
    }
    @objc private func discardCandidates() { guard !hasBlockingModal() else { return }; controller.discardMemoryReview(); render() }
    @objc private func retry() { guard !hasBlockingModal() else { return }; controller.retryPendingMemorySave() }
    @objc private func discardPending() {
        guard !hasBlockingModal(), controller.canRetryMemorySave, let context = controller.character else { return }
        confirm("放弃这次尚未保存的记忆变更？", "之前保存的记忆保持不变。") { [weak self] in
            guard let self, !self.hasBlockingModal(), self.controller.character == context else { return }
            self.controller.discardPendingMemorySave()
        }
    }
}

@MainActor private final class MemorySourceButton: NSButton {
    private weak var source: NSTextField?
    init(source: NSTextField) {
        self.source = source; super.init(frame: .zero)
        title = "查看来源"; bezelStyle = .rounded; target = self; action = #selector(toggle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { source?.isHidden.toggle(); title = source?.isHidden == true ? "查看来源" : "收起来源" }
}
