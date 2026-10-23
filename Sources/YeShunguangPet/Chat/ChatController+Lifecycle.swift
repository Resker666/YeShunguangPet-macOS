import AppKit

extension ChatController {
    func startLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(self, selector: #selector(chatWillSleep), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(chatDidWake), name: name, object: nil)
        }
    }
    func stopLifecycleObservers() { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc nonisolated private func chatWillSleep(_ notification: Notification) { dispatchSleeping(true) }
    @objc nonisolated private func chatDidWake(_ notification: Notification) { dispatchSleeping(false) }
    nonisolated private func dispatchSleeping(_ value: Bool) {
        if Thread.isMainThread { MainActor.assumeIsolated { self.setSleeping(value) } }
        else { Task { @MainActor [weak self] in self?.setSleeping(value) } }
    }
}
