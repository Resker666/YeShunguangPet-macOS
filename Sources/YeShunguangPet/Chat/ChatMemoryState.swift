import Foundation
import PetCore

struct PendingMemoryChange: Sendable {
    let token = UUID()
    let characterID: String
    let expectedRevision: UInt64
    let memories: [ChatMemory]
}

struct MemoryReviewState: Equatable, Sendable {
    let id = UUID()
    let context: ChatCharacter
    let snapshot: MemoryExtractionSnapshot
    let candidates: [ChatMemoryCandidate]
    let duplicateCount: Int
    var editedTexts: [UUID: String]
    var selectedIDs = Set<UUID>()
    init(context: ChatCharacter, snapshot: MemoryExtractionSnapshot, batch: MemoryCandidateBatch) {
        self.context = context; self.snapshot = snapshot; self.candidates = batch.candidates; self.duplicateCount = batch.duplicateCount
        editedTexts = Dictionary(uniqueKeysWithValues: batch.candidates.map { ($0.id, $0.text) })
    }
}

enum ChatRequestKind { case conversation, memoryExtraction }
