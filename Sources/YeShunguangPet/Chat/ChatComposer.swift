import AppKit

@MainActor class ChatComposer: NSTextView {
    var onSend: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, !hasMarkedText() {
            onSend?()
        } else { super.keyDown(with:event) }
    }
    override func didChangeText() { super.didChangeText(); onTextChange?(string) }
}
