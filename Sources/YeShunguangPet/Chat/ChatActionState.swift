import Foundation
import PetCore

struct ChatActionProposal: Equatable {
    let id: UUID
    let context: ChatCharacter
    let requestGeneration, connectionGeneration: UInt64
    let originalDraft, userInput: String
    let action: ChatAction
    let expectedSnapshot: ChatAppSnapshot
}
