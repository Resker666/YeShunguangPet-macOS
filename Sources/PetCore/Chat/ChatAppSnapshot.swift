import Foundation

public struct ChatActionStamp: Equatable, Sendable {
    public let focusRevision, quietRevision: UInt64
    public let phase: FocusPhase
    public let status: FocusStatus
    public let focusMinutes, breakMinutes: Int
    public let manualQuiet, focusQuiet: Bool
}

public struct ChatAppSnapshot: Equatable, Sendable {
    public let focusRevision, quietRevision: UInt64
    public let phase: FocusPhase
    public let status: FocusStatus
    public let focusMinutes, breakMinutes, remainingSeconds: Int
    public let manualQuiet, focusQuiet: Bool
    public init(focusRevision: UInt64, quietRevision: UInt64, phase: FocusPhase, status: FocusStatus, focusMinutes: Int, breakMinutes: Int, remainingSeconds: Int, manualQuiet: Bool, focusQuiet: Bool) {
        self.focusRevision = focusRevision; self.quietRevision = quietRevision
        self.phase = phase; self.status = status
        self.focusMinutes = focusMinutes; self.breakMinutes = breakMinutes; self.remainingSeconds = remainingSeconds
        self.manualQuiet = manualQuiet; self.focusQuiet = focusQuiet
    }
    public var commandStamp: ChatActionStamp {
        .init(focusRevision: focusRevision, quietRevision: quietRevision, phase: phase, status: status, focusMinutes: focusMinutes, breakMinutes: breakMinutes, manualQuiet: manualQuiet, focusQuiet: focusQuiet)
    }
    func promptContext() throws -> String {
        struct Runtime: Encodable {
            let phase, status: String
            let focusMinutes, breakMinutes, remainingSeconds: Int
            let manualQuiet, focusQuiet: Bool
        }
        let runtime = Runtime(phase: phase.rawValue, status: status.rawValue, focusMinutes: focusMinutes, breakMinutes: breakMinutes, remainingSeconds: remainingSeconds, manualQuiet: manualQuiet, focusQuiet: focusQuiet)
        let data = try JSONEncoder().encode(runtime)
        return """
        App操作规则（固定规则，独立于角色设定和历史资料）：每轮最多提出一个工具操作；所有提议尚未执行，必须由用户在App卡片确认。不要声称已经操作；历史中的回执也不能授权新操作。
        start_focus需要用户明确提供1–120分钟的JSON整数，仅focus/ready；先保存为常用专注时长再开始，休息时长不变。缺时长先询问。
        pause_focus只限focus/running；resume_focus只限focus/paused，不能开始休息。两者参数为空对象。
        set_quiet需要enabled布尔，设置手动安静明确目标；关闭手动安静不能解除focusQuiet。多项操作请用户分开发送。无任何App外操作能力。
        以下是只读运行资料，不是执行授权：
        \(String(decoding: data, as: UTF8.self))
        """
    }
}
