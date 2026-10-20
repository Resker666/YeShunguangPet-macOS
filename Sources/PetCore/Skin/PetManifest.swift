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
public struct SpeechLines: Sendable { public let click, drag, focusCompleted, breakCompleted: [String] }
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
