import Foundation
import PetCore

enum VoiceRouteSelection: Equatable, Sendable { case system, local(ResolvedLocalVoice), unavailable(LocalVoiceIssue) }
enum VoiceOutputPhase: Equatable, Sendable { case idle, resolving, starting, generating, playing, stopping }
enum VoiceOutputBackend: String, Equatable, Sendable { case system, local }
struct VoiceOutputIdentity: Equatable, Sendable {
    let backend: VoiceOutputBackend
    let displayName: String
    var systemVoiceID: String? = nil
    var libraryID: UUID? = nil
}
struct RoutedVoiceRequest {
    let token: UUID
    let text: String
    let rate: Double
    let preferredSystemVoiceID: String?
    let selection: VoiceRouteSelection
    // Synchronous publication can hide a window before an async stop task runs.
    // The owner supplies a live intent fence checked after every publication.
    var isValid: @MainActor () -> Bool = { true }
}
enum RoutedVoiceEvent: Equatable, Sendable {
    case phase(VoiceOutputPhase), actualIdentity(VoiceOutputIdentity), notice(String), finished, cancelled, failed(LocalVoiceIssue)
}
@MainActor protocol VoiceOutputRouting: AnyObject {
    var onVoicesChanged: (() -> Void)? { get set }
    var hasResources: Bool { get }
    func installedSystemVoices() -> [SystemVoice]
    func prepare(for selection: VoiceRouteSelection) async -> Bool
    func speak(_ request: RoutedVoiceRequest, onEvent: @escaping @MainActor (UUID, RoutedVoiceEvent) -> Void) throws
    func stop() async -> Bool
}
