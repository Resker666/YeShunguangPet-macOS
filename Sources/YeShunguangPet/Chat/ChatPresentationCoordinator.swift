import AppKit

// Hosts render one shared conversation; only this owner closes it logically.
enum ChatPresentationMode: Hashable { case full, quick }
@MainActor protocol ChatPresentationHosting: AnyObject {
    var isPresentationVisible: Bool { get }
    var hasBlockingSheet: Bool { get }
    var hasMarkedInput: Bool { get }
    var inputSelection: NSRange { get set }
    func setPresentationCallbacks(onClose: @escaping () -> Void, onVisibility: @escaping () -> Void)
    func presentForHandoff(selection: NSRange)
    func hideForHandoff()
    func resetLogicalDrafts()
    func beginTermination()
    func cancelTermination()
    func dispose()
}

enum ChatInputSelection {
    static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let value = text as NSString, length = value.length
        var start = range.location == NSNotFound ? length : min(max(0, range.location), length)
        var end = start + min(range.length, length - start)
        if start < length { start = value.rangeOfComposedCharacterSequence(at: start).location }
        if end > start, end < length {
            let character = value.rangeOfComposedCharacterSequence(at: end)
            if character.location < end { end = NSMaxRange(character) }
        }
        return NSRange(location: start, length: max(0, end - start))
    }
}

@MainActor final class ChatPresentationCoordinator {
    private let controller: ChatController
    private let onPresented: (Bool) -> Void
    private var hosts = [ChatPresentationMode: any ChatPresentationHosting]()
    private(set) var activeMode: ChatPresentationMode?
    private var presentationGeneration: UInt64 = 0
    private var presented = false, terminating = false, disposed = false
    var hasBlockingSheet: Bool { hosts.values.contains { $0.hasBlockingSheet } }
    var isQuickVisible: Bool { activeMode == .quick && hosts[.quick]?.isPresentationVisible == true }
    init(controller: ChatController, onPresented: @escaping (Bool) -> Void) { self.controller = controller; self.onPresented = onPresented }
    func register(_ host: any ChatPresentationHosting, for mode: ChatPresentationMode) {
        guard !disposed, hosts[mode] == nil else { return }
        hosts[mode] = host
        bind(host, mode: mode, epoch: presentationGeneration)
    }
    private func bind(_ host: any ChatPresentationHosting, mode: ChatPresentationMode, epoch: UInt64) {
        host.setPresentationCallbacks(onClose: { [weak self] in
            guard let self, !self.disposed, !self.terminating, self.activeMode == mode, self.presentationGeneration == epoch else { return }
            self.closeActive()
        }, onVisibility: { [weak self] in
            guard let self, !self.disposed, !self.terminating, self.activeMode == mode, self.presentationGeneration == epoch else { return }
            self.updatePresented()
        })
    }
    func present(_ mode: ChatPresentationMode) {
        guard !disposed, !terminating, !hasBlockingSheet, !hosts.values.contains(where: { $0.hasMarkedInput }), let target = hosts[mode] else { return }
        let selection = activeMode.flatMap { hosts[$0]?.inputSelection } ?? target.inputSelection
        presentationGeneration &+= 1
        let old = activeMode; activeMode = mode
        bind(target, mode: mode, epoch: presentationGeneration)
        if let old, old != mode { hosts[old]?.hideForHandoff() }
        target.presentForHandoff(selection: selection)
        updatePresented()
    }
    func closeActive() {
        guard !disposed, !terminating, activeMode != nil, !hasBlockingSheet,
              !hosts.values.contains(where: { $0.hasMarkedInput }) else { return }
        presentationGeneration &+= 1; activeMode = nil
        for host in hosts.values { host.hideForHandoff(); host.resetLogicalDrafts() }
        controller.windowClosed()
        updatePresented()
    }
    private func updatePresented() {
        let visible = !disposed && activeMode.flatMap { hosts[$0]?.isPresentationVisible } == true
        guard visible != presented else { return }
        presented = visible; controller.setPresented(visible); onPresented(visible)
    }
    func beginTermination() {
        guard !disposed else { return }; terminating = true; presentationGeneration &+= 1
        for host in hosts.values { host.beginTermination(); host.resetLogicalDrafts() }
    }
    func cancelTermination() {
        guard !disposed else { return }; terminating = false; presentationGeneration &+= 1
        for host in hosts.values { host.cancelTermination() }
        if let mode = activeMode, let host = hosts[mode] { bind(host, mode: mode, epoch: presentationGeneration) }
        updatePresented()
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; presentationGeneration &+= 1; activeMode = nil
        for host in hosts.values { host.dispose() }; hosts.removeAll(); updatePresented()
    }
}
