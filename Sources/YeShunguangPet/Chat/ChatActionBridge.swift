import Foundation
import Combine
import PetCore

@MainActor protocol ChatActionExecuting: AnyObject {
    var onChange: (() -> Void)? { get set }
    func snapshot() -> ChatAppSnapshot
    func execute(_ action: ChatAction, expected: ChatAppSnapshot) -> ChatActionExecutionResult
    func dispose()
}

@MainActor final class FocusChatActionBridge: ChatActionExecuting {
    var onChange: (() -> Void)?
    private let session: PetSession, focus: FocusController
    private let canDispatch: () -> Bool
    private var observation: AnyCancellable?
    private var reading = false, executing = false, disposed = false
    init(session: PetSession, focus: FocusController, canDispatch: @escaping () -> Bool) {
        self.session = session; self.focus = focus; self.canDispatch = canDispatch
        observation = focus.$actionRevision.dropFirst().sink { [weak self] _ in
            // @Published sends before assignment; read only after the current mutation.
            Task { @MainActor [weak self] in
                guard let self, !self.disposed, !self.reading else { return }
                self.onChange?()
            }
        }
        let previous = session.onQuietChange
        session.onQuietChange = { [weak self] in
            previous?()
            guard let self, !self.disposed, !self.reading else { return }
            self.onChange?()
        }
    }
    func snapshot() -> ChatAppSnapshot {
        if !reading && !disposed {
            reading = true
            focus.refreshTime()
            reading = false
        }
        return .init(focusRevision: focus.actionRevision, quietRevision: session.quietRevision,
                     phase: focus.phase, status: focus.status, focusMinutes: focus.focusMinutes, breakMinutes: focus.breakMinutes,
                     remainingSeconds: focus.remainingSeconds, manualQuiet: session.isQuiet, focusQuiet: session.focusQuiet)
    }
    func execute(_ action: ChatAction, expected: ChatAppSnapshot) -> ChatActionExecutionResult {
        guard !disposed, !executing, canDispatch(), !session.gate.exiting, !session.gate.sleeping else { return .expired("当前无法执行，请重新发送。") }
        executing = true
        defer { executing = false }
        let before = snapshot()
        guard before.commandStamp == expected.commandStamp else { return .expired("专注或安静状态已经变化，请重新发送。") }
        // These receipts contain only local fixed text and bounded typed values, never raw errors.
        func finish(_ outcome: ChatActionReceipt.Outcome, _ detail: String) -> ChatActionExecutionResult {
            .finished(try! ChatActionReceipt(action: action, outcome: outcome, detail: detail))
        }
        switch action {
        case .startFocus(let minutes):
            guard (1...120).contains(minutes), before.phase == .focus, before.status == .ready, focus.canStartPreset else {
                return finish(.failed, "未开始专注：请先回到准备专注状态。")
            }
            do { try focus.applyDurations(focusMinutes: minutes, breakMinutes: before.breakMinutes) }
            catch { return finish(.failed, "未开始专注：常用时长未能保存，请检查设置保存状态。") }
            // Saving can synchronously invoke application callbacks. Recheck before starting.
            guard canDispatch(), !session.gate.exiting, !session.gate.sleeping, focus.phase == .focus, focus.status == .ready,
                  focus.focusMinutes == minutes, focus.breakMinutes == before.breakMinutes else {
                return finish(.failed, "常用时长已保存，但当前状态已变化，未开始专注。")
            }
            focus.startOrResume()
            let after = snapshot()
            guard after.phase == .focus, after.status == .running, after.focusMinutes == minutes else { return finish(.failed, "常用时长已保存，但未能开始专注。") }
            return finish(.applied, "已开始\(minutes)分钟专注，常用专注时长已保存为\(minutes)分钟。")
        case .pauseFocus:
            guard before.phase == .focus, before.status == .running else { return finish(.failed, "未暂停：当前没有正在运行的专注。") }
            focus.pause()
            let after = snapshot()
            guard after.phase == .focus, after.status == .paused else { return finish(.failed, "未暂停：专注已经完成或当前无法操作。") }
            return finish(.applied, "已暂停当前专注。")
        case .resumeFocus:
            guard before.phase == .focus, before.status == .paused else { return finish(.failed, "未继续：当前没有已暂停的专注，未开始下一段。") }
            focus.startOrResume()
            let after = snapshot()
            guard after.phase == .focus, after.status == .running else { return finish(.failed, "未能继续当前专注，未开始下一段。") }
            return finish(.applied, "已继续当前专注。")
        case .setQuiet(let enabled):
            let same = before.manualQuiet == enabled
            session.setQuiet(enabled)
            let after = snapshot()
            guard after.manualQuiet == enabled else { return finish(.failed, "未能修改手动安静状态。") }
            let detail = same ? "手动安静已经处于此状态。" : (enabled ? "已开启手动安静。" : "已关闭手动安静。")
            return finish(same ? .alreadySatisfied : .applied, detail + (after.focusQuiet ? "专注安静仍生效。" : "专注安静未生效。"))
        }
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true; observation?.cancel(); observation = nil; onChange = nil
        // The weak quiet callback becomes inert; leave any subsequently installed observer intact.
    }
}
