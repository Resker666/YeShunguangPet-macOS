import Foundation

public enum PetAction: String, CaseIterable, Sendable { case idle, runningRight, runningLeft, waving, jumping, failed, waiting, running, review }
public struct FrameLocation: Hashable, Sendable {
    public let row: Int, column: Int
    public init(row: Int, column: Int) { self.row=row; self.column=column }
}
public struct AnimationDefinition: Sendable {
    public let row: Int, startColumn: Int, durationsMs: [Int], loop: Bool
    public init(row: Int = 0, startColumn: Int = 0, durationsMs: [Int], loop: Bool = false) { self.row=row; self.startColumn=startColumn; self.durationsMs=durationsMs; self.loop=loop }
}
public struct SpeechLines: Codable, Equatable, Sendable {
    public let click, drag, focusCompleted, breakCompleted: [String]
    public init(click:[String],drag:[String],focusCompleted:[String],breakCompleted:[String]) {
        self.click=click;self.drag=drag;self.focusCompleted=focusCompleted;self.breakCompleted=breakCompleted
    }
    public static let defaults=SpeechLines(click:["我在，今天也一起加油吧。","需要我陪你一会儿吗？"],drag:["换个位置，继续陪你。","就在这里吧。"],focusCompleted:["这轮专注完成了，歇一会儿吧。","又完成了一段专注，辛苦了。"],breakCompleted:["休息结束，准备好再开始吧。","下一轮，我也在。"])
    public func lines(for event:SpeechEvent)->[String] {
        switch event {case .click:return click;case .drag:return drag;case .focusCompleted:return focusCompleted;case .breakCompleted:return breakCompleted}
    }
}
public struct PetBehaviorRule: Equatable, Sendable { public let condition: String; public let action: PetAction; public let weight, cooldownSeconds: Int }
public struct PetBehaviorRules: Equatable, Sendable { public let schemaVersion: Int; public let rules: [PetBehaviorRule] }
public struct PetManifest: Sendable {
    public let schemaVersion: Int
    public let id, name, description, spriteSheet: String
    public let cellWidth, cellHeight, columns, rows: Int
    public let animations: [PetAction:AnimationDefinition]
    public let lookDirections: [FrameLocation]
    public let speech: SpeechLines?
    public let behavior: PetBehaviorRules?
}
