import Foundation
import Darwin
import XCTest
import PetCore

@MainActor final class LocalVoiceProcessTests: XCTestCase {
    func testClosedWorkerInputReturnsFailureInsteadOfKillingHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let service = LocalVoiceProcess(workerURL: try LocalVoiceServiceFixtures.helper(root: root, mode: "closed-input"))
        let work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID())
        // Detect process-fatal SIGPIPE even if this XCTest host inherited SIG_IGN.
        let previous = Darwin.signal(SIGPIPE, SIG_DFL)
        defer { _ = Darwin.signal(SIGPIPE, previous) }
        do {
            _ = try await service.generate(requestID: UUID(), text: "管道关闭时保持桌宠运行", speedFactor: 1)
            XCTFail("closed input must fail")
        } catch { XCTAssertEqual(error as? LocalVoiceIssue, .unavailable) }
        let stopped = await service.stop()
        XCTAssertTrue(stopped); XCTAssertFalse(service.hasResources)
    }
    func testReadyFloodOrTimeoutKeepsMainActorResponsiveAndKillsOnlyOwnedPID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let sentinel = Process(); sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep"); sentinel.arguments = ["30"]
        try sentinel.run(); defer { sentinel.terminate() }
        for mode in ["flood", "stderr", "hang", "malformed"] {
            let service = LocalVoiceProcess(workerURL: try LocalVoiceServiceFixtures.helper(root: root, mode: mode), limits: .init(ready: 0.15, generate: 0.15, stopGrace: 0.05, killGrace: 0.5, monitorInterval: 0.01))
            let work = root.appendingPathComponent(mode); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            var ticks = 0
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    ticks += 1
                }
            }
            let task = Task { try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID()) }
            do { try await task.value; XCTFail("must fail: \(mode)") } catch {}
            heartbeat.cancel()
            if mode == "hang" { XCTAssertGreaterThan(ticks, 3, "main actor must run during blocked startup") }
            let stopped = await service.stop()
            XCTAssertTrue(stopped); XCTAssertFalse(service.hasResources); XCTAssertTrue(sentinel.isRunning)
        }
    }
    func testOldExitCannotRetireNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let worker = try LocalVoiceServiceFixtures.helper(root: root, mode: "normal"), service = LocalVoiceProcess(workerURL: worker)
        let work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID())
        let stopped = await service.stop(); XCTAssertTrue(stopped)
        try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID())
        let output = try await service.generate(requestID: UUID(), text: "你好，测试分片协议", speedFactor: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(service.hasResources)
        let finalStop = await service.stop(); XCTAssertTrue(finalStop)
    }
    func testWrongIDsAndGenerationTimeoutAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        for mode in ["wrong-id", "generate-hang", "duplicate"] {
            let service = LocalVoiceProcess(workerURL: try LocalVoiceServiceFixtures.helper(root: root, mode: mode), limits: .init(ready: 1, generate: 0.1, stopGrace: 0.05, killGrace: 0.5, monitorInterval: 0.01))
            let work = root.appendingPathComponent(mode); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            do {
                try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID())
                _ = try await service.generate(requestID: UUID(), text: "测试", speedFactor: 0.7)
                XCTFail("invalid child must fail")
            } catch {}
            let result = await service.stop(); XCTAssertTrue(result)
        }
    }
    func testRSSLimitStopsOnlyTheOwnedChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        let service = LocalVoiceProcess(workerURL: try LocalVoiceServiceFixtures.helper(root: root, mode: "hang"), limits: .init(ready: 2, generate: 2, stopGrace: 0.05, killGrace: 0.5, monitorInterval: 0.01), rss: { _ in UInt64.max })
        let work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID())
            XCTFail("memory limit must fail")
        } catch { XCTAssertEqual(error as? LocalVoiceIssue, .memoryLimit) }
        let confirmed = await service.stop(); XCTAssertTrue(confirmed)
    }
    func testGeneratedFileValidationRejectsMissingAndLinkedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), voice = try LocalVoiceServiceFixtures.voice(root: root)
        for mode in ["normal", "missing", "link"] {
            let service = LocalVoiceProcess(workerURL: try LocalVoiceServiceFixtures.helper(root: root, mode: mode))
            let work = root.appendingPathComponent(mode); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try await service.start(configuration: configuration, voice: voice, workDirectory: work, session: UUID())
            let url = try await service.generate(requestID: UUID(), text: "新测试文本", speedFactor: 1.3)
            if mode == "normal" { XCTAssertNoThrow(try LocalVoiceAudioSnapshot.read(url)) }
            else { XCTAssertThrowsError(try LocalVoiceAudioSnapshot.read(url)) }
            let confirmed = await service.stop(); XCTAssertTrue(confirmed)
        }
    }
}
