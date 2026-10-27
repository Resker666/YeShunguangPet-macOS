import Foundation
import XCTest
import PetCore

@MainActor final class LocalVoiceOutputTests: XCTestCase {
    func testStopDuringLaunchGenerationAndPlaybackWaitsForResources() async throws {
        for phase in ["launch", "generate", "play"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
            let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer()
            process.holdStart = phase == "launch"; process.holdGeneration = phase == "generate"
            let output = LocalVoiceOutput(process: process, player: player, configuration: { configuration })
            try output.start(.init(token: UUID(), voice: voice, text: "测试", rate: 0.5)) { _, _ in }
            try await chatEventually { phase == "play" ? player.plays == 1 : phase == "generate" ? process.generates == 1 : process.starts == 1 }
            process.holdStop = true
            let stopped = Task { await output.stop() }
            try await chatEventually { process.stops == 1 }
            XCTAssertTrue(output.hasResources)
            process.releaseStop()
            let confirmed = await stopped.value
            XCTAssertTrue(confirmed)
            XCTAssertFalse(output.hasResources)
            XCTAssertFalse(FileManager.default.fileExists(atPath: process.directory!.path))
        }
    }
    func testPrepareReusesOnlyIdleSameVoiceAndStopAlwaysDisposesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer()
        let output = LocalVoiceOutput(process: process, player: player, configuration: { configuration })
        try output.start(.init(token: UUID(), voice: voice, text: "第一句", rate: 0.5)) { _, _ in }
        try await chatEventually { player.plays == 1 }; player.finish()
        let reused = await output.prepare(voice: voice); XCTAssertTrue(reused)
        try output.start(.init(token: UUID(), voice: voice, text: "第二句", rate: 0.5)) { _, _ in }
        try await chatEventually { player.plays == 2 }
        XCTAssertEqual(process.starts, 1); XCTAssertEqual(process.stops, 0)
        player.finish()
        let stopped = await output.stop(); XCTAssertTrue(stopped); XCTAssertEqual(process.stops, 1)
        XCTAssertFalse(output.hasResources)
    }
    func testIdleExpiresAt180SecondsWithoutActiveWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer()
        var now = 0.0
        let output = LocalVoiceOutput(process: process, player: player, configuration: { configuration }, now: { now })
        try output.start(.init(token: UUID(), voice: voice, text: "测试", rate: 0.5)) { _, _ in }
        try await chatEventually { player.plays == 1 }
        now = 500; await output.checkIdle(); XCTAssertEqual(process.stops, 0)
        player.finish(); now = 679.999; await output.checkIdle(); XCTAssertEqual(process.stops, 0)
        now = 680; await output.checkIdle(); XCTAssertEqual(process.stops, 1)
    }
    func testInvalidAudioFailsBeforePlaybackAndStopFailureCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer()
        process.outputData = Data()
        let output = LocalVoiceOutput(process: process, player: player, configuration: { configuration })
        var failedBeforePlayback = false
        try output.start(.init(token: UUID(), voice: voice, text: "测试", rate: 0.5)) { _, event in
            if case .failed(_, let started) = event { failedBeforePlayback = !started }
        }
        try await chatEventually { failedBeforePlayback }
        XCTAssertEqual(player.plays, 0)
        process.stopResult = false
        let failedStop = await output.stop(); XCTAssertFalse(failedStop); XCTAssertTrue(output.hasResources)
        process.stopResult = true
        let retried = await output.stop(); XCTAssertTrue(retried)
    }
    func testConcurrentStopWaitersReturnAfterResourceStateIsRetired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer()
        let output = LocalVoiceOutput(process: process, player: player, configuration: { configuration })
        try output.start(.init(token: UUID(), voice: voice, text: "测试停止", rate: 0.5)) { _, _ in }
        try await chatEventually { player.plays == 1 }
        process.holdStop = true
        let first = Task { await output.stop() }
        try await chatEventually { process.stops == 1 }
        let second = Task { let result = await output.stop(); return result && !output.hasResources }
        await Task.yield()
        process.releaseStop()
        let secondResult = await second.value, firstResult = await first.value
        XCTAssertTrue(secondResult); XCTAssertTrue(firstResult)
        XCTAssertEqual(process.stops, 1)
    }
    func testSnapshotRejectsMissingLinkedAndEmptyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("missing.wav")
        XCTAssertThrowsError(try LocalVoiceAudioSnapshot.read(missing))
        let good = root.appendingPathComponent("good.wav"), link = root.appendingPathComponent("linked.wav")
        try LocalVoiceFixtures.pcm(seconds: 0.1).write(to: good)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
        XCTAssertThrowsError(try LocalVoiceAudioSnapshot.read(link))
        XCTAssertNoThrow(try LocalVoiceAudioSnapshot.read(good))
        try Data().write(to: good)
        XCTAssertThrowsError(try LocalVoiceAudioSnapshot.read(good))
    }
    func testDifferentVoicePreparationStopsIdleWorkerAndLatePlayerEventIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let other = try LocalVoiceServiceFixtures.voice(root: root, id: "other")
        let process = ControlledLocalVoiceProcess(), player = ControlledLocalVoicePlayer()
        let output = LocalVoiceOutput(process: process, player: player, configuration: { configuration })
        let old = UUID()
        var events = [LocalVoiceOutputEvent]()
        try output.start(.init(token: old, voice: voice, text: "第一句", rate: 0.5)) { _, event in events.append(event) }
        try await chatEventually { player.plays == 1 }
        let late = player.callback
        player.finish()
        let prepared = await output.prepare(voice: other)
        XCTAssertTrue(prepared); XCTAssertEqual(process.stops, 1)
        try output.start(.init(token: UUID(), voice: other, text: "新音色", rate: 0.5)) { _, event in events.append(event) }
        try await chatEventually { player.plays == 2 }
        let before = events
        late?(old, .failed)
        XCTAssertEqual(events, before)
        let confirmed = await output.stop(); XCTAssertTrue(confirmed)
    }
}
