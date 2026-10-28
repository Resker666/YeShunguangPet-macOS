import AppKit
import XCTest
import PetCore

@MainActor final class LocalVoiceEngineIntegrationTests: XCTestCase {
    private func configure(_ f:ChatControllerFixture,hooks:LocalVoiceEngineStore.Hooks = .live) async throws -> (ChatLocalVoiceEngineController, ControlledEngineProbe,ControlledVoiceInput,ControlledVoiceOutput,URL) {
        let input = ControlledVoiceInput(), output = ControlledVoiceOutput(), probe = ControlledEngineProbe()
        f.controller.configureVoice(services:.init(input:input,output:output),now:{ .zero })
        f.controller.configureLocalVoiceEngine(worker:LocalVoiceEngineWorker(dataRoot:f.root,hooks:hooks),probe:probe)
        try await chatEventually { f.controller.voice?.settings.isLoaded == true && f.controller.localVoices?.isLoaded == true && f.controller.localEngine?.isBusy == false }
        f.controller.voice?.settings.apply(.init(enabled:true)); await f.controller.waitForPendingWrites()
        f.controller.updateVoiceEnvironment(.init(surface:.conversation))
        return (try XCTUnwrap(f.controller.localEngine),probe,input,output,try LocalVoiceEngineFixtures.folder(f.root))
    }
    func testTextSendAndArchiveFIFORemainUsableDuringInstallation() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let gate = EngineGate(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.inspectChunk = { _,_ in gate.blockOnce() }
        let (engine,probe,input,output,folder) = try await configure(f,hooks:hooks)
        engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); try await chatEventually { gate.entered }
        f.controller.setDraft("安装期间文字继续"); XCTAssertTrue(f.controller.canSend); f.controller.send()
        try await chatEventually { f.client.count == 1 }; f.client.complete(0,answer:"已经保存")
        try await chatEventually { f.controller.conversation?.messages.count == 2 }; await f.controller.waitForPendingWrites()
        XCTAssertFalse(f.controller.hasPendingWrites); XCTAssertTrue(output.spoken.isEmpty); XCTAssertTrue(input.starts.isEmpty); XCTAssertEqual(probe.runs,0)
        gate.semaphore.signal(); await engine.waitForPending(); XCTAssertEqual(engine.phase,.installed); await f.close()
    }
    func testEngineMutationBlocksNewVoiceAndRolePackageMutation() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let gate = EngineGate(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.inspectChunk = { _,_ in gate.blockOnce() }
        let (engine,_,input,output,folder) = try await configure(f,hooks:hooks)
        f.controller.voice?.readLatest("先朗读"); try await chatEventually { output.spoken.count == 1 }
        engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); try await chatEventually { gate.entered }
        XCTAssertFalse(f.controller.canPrepareVoiceInput); f.controller.voice?.readLatest("不能播"); f.controller.voice?.beginInput(selection:.init(location:0,length:0))
        let voiceFolder = try LocalVoiceFixtures.folder(f.root)
        f.controller.localVoices?.preview(folder:voiceFolder)
        XCTAssertTrue(input.starts.isEmpty); XCTAssertEqual(output.spoken.count,1); XCTAssertNil(f.controller.localVoices?.preview)
        XCTAssertFalse(f.controller.voice?.hasOutputActivity == true)
        gate.semaphore.signal(); await engine.waitForPending(); try await chatEventually { f.controller.canPrepareVoiceInput }
        await f.close()
    }
    func testExitWaitsForProbeWithEmptyChatQueue() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let (engine,probe,_,_,folder) = try await configure(f)
        probe.hold = true; probe.holdStop = true
        engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); try await chatEventually { probe.runs == 1 }
        XCTAssertFalse(f.controller.hasPendingWrites); f.controller.beginTermination(); XCTAssertTrue(f.controller.hasPendingTerminationResources)
        var replied:Bool?
        let finish = Task { replied = await ChatTerminationCoordinator.finish(chat:f.controller,confirmSave:{ _ in true },resourceDecision:{ _ in .cancel }) }
        try await chatEventually { probe.stops > 0 }; for _ in 0..<10 { await Task.yield() }; XCTAssertNil(replied)
        probe.releaseStop(); await finish.value; XCTAssertEqual(replied,true); XCTAssertFalse(engine.hasPendingResources); await f.close()
    }
    func testProbeFailureAllowsAllThreeExitDecisions() async throws {
        for decision in 0..<3 {
            let f = try ChatControllerFixture(); try await f.open(); let (engine,probe,_,output,folder) = try await configure(f)
            probe.fail = true; probe.stopResult = false
            engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); await engine.waitForPending()
            f.controller.beginTermination(); var asked = 0
            let result = await ChatTerminationCoordinator.finish(chat:f.controller,confirmSave:{ _ in true },resourceDecision:{ _ in
                asked += 1
                if decision == 0 { probe.stopResult = true; return .retry }
                return decision == 1 ? .cancel : .exit
            })
            XCTAssertEqual(asked,1); XCTAssertEqual(result,decision != 1)
            if !result { f.controller.cancelTermination() }
            probe.stopResult = true; await engine.retryForTermination(); XCTAssertFalse(engine.hasPendingResources); XCTAssertTrue(output.spoken.isEmpty)
            await f.close()
        }
    }
    func testFullQuickHandoffAndRoleChangeKeepOneAcceptedInstall() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let (engine,probe,_,_,folder) = try await configure(f)
        probe.hold = true
        engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); try await chatEventually { probe.runs == 1 }
        let pet = try ShortcutFixture(); defer { pet.close() }
        let bar = StatusBarController(session:pet.session,updates:.init(currentVersion:ReleaseVersion(tag:"0.7.0")!,architecture:.arm64,client:NoReleaseRequests()),registry:pet.registry,chat:f.controller,onQuit:{})
        bar.openQuickChat(); bar.chatPresentation?.present(.full); bar.chatPresentation?.present(.quick)
        f.controller.activate(.init(id:"new-role",name:"新角色",description:"",skinRevision:1)); f.controller.windowClosed()
        XCTAssertTrue(f.controller.localEngine === engine); XCTAssertEqual(probe.runs,1); XCTAssertTrue(engine.isBusy)
        engine.cancelInstallation(); await engine.waitForPending(); bar.dispose(); await f.close()
    }
    func testSleepCancelsAndWakeDoesNotResumeOrReconfigure() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let (engine,probe,_,output,folder) = try await configure(f)
        probe.hold = true
        engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); try await chatEventually { probe.runs == 1 }
        f.controller.configureLocalVoiceEngine(worker:LocalVoiceEngineWorker(dataRoot:f.root),probe:ControlledEngineProbe())
        XCTAssertTrue(f.controller.localEngine === engine)
        f.controller.setSleeping(true); await engine.waitForPending(); f.controller.setSleeping(false)
        XCTAssertEqual(engine.phase,.idle); XCTAssertEqual(probe.runs,1); XCTAssertTrue(output.spoken.isEmpty)
        await f.close()
    }
    func testFailedActivationIsRetriedOnlyLocallyDuringExit() async throws {
        let f = try ChatControllerFixture(); try await f.open(); let fail = EngineFailureFlag(); var hooks = LocalVoiceEngineStore.Hooks.live
        hooks.beforeCommit = { if fail.value { throw LocalVoiceError("save failure") } }
        let (engine,probe,input,output,folder) = try await configure(f,hooks:hooks)
        engine.preview(folder:folder); await engine.waitForPending(); engine.confirmInstall(); await engine.waitForPending()
        f.controller.beginTermination(); XCTAssertTrue(f.controller.canRetryTerminationSave); XCTAssertNotNil(f.controller.terminationSaveError)
        fail.value = false; let saved = await f.controller.retryAllPendingSaves(); XCTAssertTrue(saved)
        XCTAssertNil(f.controller.terminationSaveError); XCTAssertEqual(probe.runs,1); XCTAssertTrue(input.starts.isEmpty); XCTAssertTrue(output.spoken.isEmpty)
        await f.close()
    }
}
