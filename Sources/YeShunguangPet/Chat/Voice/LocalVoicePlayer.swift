import Foundation
import AVFoundation

enum LocalVoicePlayerEvent: Equatable, Sendable { case started, finished, failed }
@MainActor protocol LocalVoicePlayerDriving: AnyObject, Sendable {
    var hasResources: Bool { get }
    func play(data: Data, token: UUID, onEvent: @escaping @MainActor (UUID, LocalVoicePlayerEvent) -> Void) throws
    func stop() async -> Bool
}
private final class LocalVoicePlayerProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let token: UUID
    let event: @Sendable (UUID, LocalVoicePlayerEvent) -> Void
    init(token: UUID, event: @escaping @Sendable (UUID, LocalVoicePlayerEvent) -> Void) { self.token = token; self.event = event }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { event(token, flag ? .finished : .failed) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { event(token, .failed) }
}
@MainActor final class LocalVoicePlayer: LocalVoicePlayerDriving {
    private var player: AVAudioPlayer?, proxy: LocalVoicePlayerProxy?, token: UUID?
    private var callback: (@MainActor (UUID, LocalVoicePlayerEvent) -> Void)?
    var hasResources: Bool { player != nil }
    func play(data: Data, token: UUID, onEvent: @escaping @MainActor (UUID, LocalVoicePlayerEvent) -> Void) throws {
        guard player == nil else { throw LocalVoiceIssue.stopping }
        let player = try AVAudioPlayer(data: data)
        let proxy = LocalVoicePlayerProxy(token: token) { [weak self] token, event in
            Task { @MainActor in self?.receive(token, event) }
        }
        player.delegate = proxy
        self.player = player; self.proxy = proxy; self.token = token; callback = onEvent
        guard player.prepareToPlay(), player.play() else { clear(); throw LocalVoiceIssue.playback }
        onEvent(token, .started)
    }
    private func receive(_ token: UUID, _ event: LocalVoicePlayerEvent) {
        guard self.token == token else { return }
        let callback = callback; clear(); callback?(token, event)
    }
    private func clear() { player?.delegate = nil; player = nil; proxy = nil; token = nil; callback = nil }
    func stop() async -> Bool {
        player?.stop()
        guard player?.isPlaying != true else { return false }
        clear(); return true
    }
}
