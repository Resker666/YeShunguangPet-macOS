import AppKit
import PetCore

@MainActor private final class ChatActionDecisionButton: NSButton {
    private let decision: () -> Void
    init(title: String, decision: @escaping () -> Void) {
        self.decision = decision; super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(decide)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func decide() { decision() }
}

@MainActor final class ChatActionCardView: NSStackView {
    private let controller: ChatController
    private let hasBlockingModal: () -> Bool
    private let label = NSTextField(wrappingLabelWithString: "")
    private let controls = NSStackView()
    private var renderedID: UUID?
    init(controller: ChatController, hasBlockingModal: @escaping () -> Bool) {
        self.controller = controller; self.hasBlockingModal = hasBlockingModal
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        label.font = .systemFont(ofSize: 13); label.textColor = .labelColor
        controls.orientation = .horizontal; controls.spacing = 6
        for view in [label, controls] {
            addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func render() {
        let card = controller.pendingAction
        isHidden = card == nil
        guard let card else { renderedID = nil; return }
        if renderedID != card.id {
            renderedID = card.id
            for view in controls.arrangedSubviews { controls.removeArrangedSubview(view); view.removeFromSuperview() }
            let title: String, detail: String
            switch card.action {
            case .startFocus(let minutes): title = "确认开始"; detail = "开始\(minutes)分钟专注；常用专注时长将改为\(minutes)分钟，休息时长不变。"
            case .pauseFocus: title = "确认暂停"; detail = "暂停当前专注。"
            case .resumeFocus: title = "确认继续"; detail = "继续已暂停的专注，不开始下一段。"
            case .setQuiet(let enabled): title = enabled ? "确认开启" : "确认关闭"; detail = (enabled ? "开启" : "关闭") + "手动安静。关闭手动安静不会解除专注安静。"
            }
            label.stringValue = "尚未执行 · App操作提议\n" + detail
            let confirm = ChatActionDecisionButton(title: title) { [weak self] in
                guard let self, !self.hasBlockingModal(), self.controller.canDecideAction else { return }
                self.controller.confirmAction(id: card.id, for: card.context)
            }
            let cancel = ChatActionDecisionButton(title: "取消") { [weak self] in
                guard let self, !self.hasBlockingModal(), self.controller.canDecideAction else { return }
                self.controller.cancelAction(id: card.id, for: card.context)
            }
            controls.addArrangedSubview(confirm); controls.addArrangedSubview(cancel)
        }
        for button in controls.arrangedSubviews.compactMap({ $0 as? NSButton }) { button.isEnabled = !hasBlockingModal() && controller.canDecideAction }
    }
}
