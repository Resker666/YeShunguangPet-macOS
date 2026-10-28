import Foundation
import XCTest
import PetCore

@MainActor final class ChatLocalVoiceEngineControllerTests: XCTestCase {
    private func setup(hooks: LocalVoiceEngineStore.Hooks = .live) throws -> (URL,URL,LocalVoiceEngineWorker,ControlledEngineProbe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = try LocalVoiceEngineFixtures.folder(root)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return (root,folder,LocalVoiceEngineWorker(dataRoot:root,hooks:hooks),ControlledEngineProbe())
    }
    private func controller(_ worker:LocalVoiceEngineWorker,_ probe:ControlledEngineProbe, stop:@escaping @MainActor () async -> Bool = { true }) -> ChatLocalVoiceEngineController {
        .init(worker:worker,probe:probe,canStart:{ true },stopOutput:stop,onActivated:{})
    }
    private func wait(_ predicate: ()->Bool) async {
        let end = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(predicate())
    }
    func testOnlyOneConfirmedInstallAndProbeCanActivate() async throws {
        let (root,folder,worker,probe) = try setup(), c = controller(worker,probe)
        c.preview(folder:folder); await c.waitForPending(); XCTAssertNotNil(c.preview); XCTAssertEqual(probe.runs,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("LocalVoice/Engine").path))
        c.confirmInstall(); c.confirmInstall(); await c.waitForPending()
        XCTAssertEqual(c.phase,.installed); XCTAssertEqual(probe.runs,1); XCTAssertFalse(c.hasUnsaved)
        let (_,folder2,w2,p2) = try setup(), blocked = controller(w2,p2,stop:{ false })
        blocked.preview(folder:folder2); await blocked.waitForPending(); blocked.confirmInstall(); await blocked.waitForPending()
        XCTAssertEqual(p2.runs,0); XCTAssertNotNil(blocked.error)
    }
    func testFailedActivationRetainsCandidateAcrossRoleAndWindowChanges() async throws {
        let fail = EngineFailureFlag(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.beforeCommit = { if fail.value { throw LocalVoiceError("write failure") } }
        let (root,folder,worker,probe) = try setup(hooks:hooks), c = controller(worker,probe)
        c.preview(folder:folder); await c.waitForPending(); c.confirmInstall(); await c.waitForPending()
        XCTAssertTrue(c.hasUnsaved); XCTAssertFalse(c.blocksServices)
        let versions = root.appendingPathComponent("LocalVoice/Engine/Versions"), names = try FileManager.default.contentsOfDirectory(atPath:versions.path)
        XCTAssertEqual(names.count,1)
        c.cancelPreview(); try FileManager.default.removeItem(at:folder); fail.value = false
        c.retryPending(); await c.waitForPending(); XCTAssertEqual(c.phase,.installed); XCTAssertEqual(probe.runs,1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:versions.path),names)
    }
    func testPendingRetryReleasesAndReacquiresLease() async throws {
        let fail = EngineFailureFlag(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.beforeCommit = { if fail.value { throw LocalVoiceError("write failure") } }
        let (root,folder,worker,probe) = try setup(hooks:hooks), c = controller(worker,probe)
        c.preview(folder:folder); await c.waitForPending(); c.confirmInstall(); await c.waitForPending()
        let store = LocalVoiceEngineStore(dataRoot:root), lease = try store.acquire(); lease.release()
        let raw = Data("external change".utf8); try raw.write(to:root.appendingPathComponent("LocalVoice/Engine/current.json"));fail.value = false
        c.retryPending(); await c.waitForPending(); XCTAssertTrue(c.hasUnsaved); XCTAssertNotNil(c.error)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("LocalVoice/Engine/current.json")),raw)
        c.cancelInstallation(); await c.waitForPending(); XCTAssertFalse(c.hasUnsaved)
    }
    func testCancelBeforeAndAfterActivationDoesNotDeleteCurrent() async throws {
        for after in [false,true] {
            let gate = EngineGate(); var hooks = LocalVoiceEngineStore.Hooks.live
            if after { hooks.afterCommit = { gate.blockOnce() } } else { hooks.beforeCommit = { gate.blockOnce() } }
            let (root,folder,worker,probe) = try setup(hooks:hooks), c = controller(worker,probe)
            c.preview(folder:folder); await c.waitForPending(); c.confirmInstall()
            await wait { gate.entered }; c.cancelInstallation(); gate.semaphore.signal(); await c.waitForPending()
            XCTAssertEqual(c.phase,after ? .installed : .idle)
            let current = root.appendingPathComponent("LocalVoice/Engine/current.json")
            XCTAssertEqual(FileManager.default.fileExists(atPath:current.path),after)
        }
    }
    func testCancelledCopyCleansOnlyItsOwnCandidate() async throws {
        let gate = EngineGate(), fail = EngineFailureFlag(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.inspectChunk = { _,_ in gate.blockOnce() }; hooks.beforeRemove = { _ in if fail.value { throw LocalVoiceError("cleanup failure") } }
        let (root,folder,worker,probe) = try setup(hooks:hooks), c = controller(worker,probe)
        c.preview(folder:folder); await c.waitForPending(); c.confirmInstall(); await wait { gate.entered }
        XCTAssertTrue(c.blocksServices); c.beginTermination(); c.cancelTermination(); gate.semaphore.signal(); await c.waitForPending()
        XCTAssertTrue(c.hasUnsaved); XCTAssertEqual(probe.runs,0)
        fail.value = false; c.retryPending(); await c.waitForPending(); XCTAssertFalse(c.hasUnsaved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("LocalVoice/Engine/Versions").path),[])
    }
    func testProbeStopFailureRetainsCandidateUntilConfirmedExit() async throws {
        let (root,folder,worker,probe) = try setup(), c = controller(worker,probe)
        probe.fail = true; probe.stopResult = false
        c.preview(folder:folder); await c.waitForPending(); c.confirmInstall(); await c.waitForPending()
        XCTAssertTrue(c.hasPendingResources); XCTAssertTrue(c.blocksServices); XCTAssertTrue(c.hasUnsaved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("LocalVoice/Engine/Versions").path).count,1)
        probe.stopResult = true; c.retryPending(); await c.waitForPending()
        XCTAssertFalse(c.hasPendingResources); XCTAssertFalse(c.hasUnsaved)
    }
    func testCheckBothDescriptorGenerationsDoesNotSwitchCurrent() async throws {
        for legacy in [true, false] {
            let (root,folder,worker,probe) = try setup(), c = controller(worker,probe)
            if legacy { _ = try LocalVoiceServiceFixtures.configuration(root:root) }
            else { c.preview(folder:folder); await c.waitForPending(); c.confirmInstall(); await c.waitForPending() }
            let current = root.appendingPathComponent("LocalVoice/Engine/current.json"), before = try Data(contentsOf:current), runs = probe.runs
            c.checkCurrent(); await c.waitForPending()
            XCTAssertEqual(c.phase,.installed); XCTAssertEqual(probe.runs,runs+1)
            XCTAssertEqual(try Data(contentsOf:current),before)
        }
    }
    func testCancelledUnconfirmedPreviewCannotBecomeAnInstall() async throws {
        let (_,folder,worker,probe) = try setup(), c = controller(worker,probe)
        c.preview(folder:folder); c.cancelPreview(); await c.waitForPending(); c.confirmInstall(); await c.waitForPending()
        XCTAssertNil(c.preview); XCTAssertEqual(c.phase,.idle); XCTAssertEqual(probe.runs,0)
    }
    func testCheckMissingIsReadOnlyAndDoesNotEnableAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let c = controller(LocalVoiceEngineWorker(dataRoot:root),ControlledEngineProbe())
        c.checkCurrent(); await c.waitForPending(); XCTAssertNotNil(c.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
}
