import Foundation
import PetCore

struct PendingMemoryChange: Sendable {
    let token = UUID()
    let characterID: String
    let expectedRevision: UInt64
    let memories: [ChatMemory]
}
