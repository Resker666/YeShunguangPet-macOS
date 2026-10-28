import Foundation
import XCTest
import Darwin
import PetCore

@MainActor final class LocalVoiceEngineProbeTests: XCTestCase {
    private func setup(_ mode: String) throws -> (URL, LocalVoiceEngineConfiguration, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalVoiceServiceFixtures.configuration(root: root), script = root.appendingPathComponent(mode + ".py")
        try Data(Self.helper.utf8).write(to: script); return (root, configuration, script)
    }
    private func limits() -> LocalVoiceEngineProbe.Limits { .init(timeout: 0.3, stopGrace: 0.1, killGrace: 0.5) }
    func testProbeRejectsWrongReplyAndOversizedOutput() async throws {
        for mode in ["valid", "wrong", "extra", "duplicate", "flood", "stderr", "nonzero"] {
            let (_, configuration, script) = try setup(mode), probe = LocalVoiceEngineProbe(scriptURL: script, limits: limits())
            do { let report = try await probe.run(configuration: configuration, requestID: UUID()); XCTAssertEqual(mode,"valid"); XCTAssertEqual(report.pythonVersion,"3.12.14") }
            catch { XCTAssertNotEqual(mode,"valid") }
            XCTAssertFalse(probe.hasResources); let stopped = await probe.stop(); XCTAssertTrue(stopped)
        }
    }
    func testCancelAndTimeoutConfirmOwnedPIDExit() async throws {
        for cancel in [false, true] {
            let (_, configuration, script) = try setup("hang"), probe = LocalVoiceEngineProbe(scriptURL: script, limits: limits())
            let task = Task { try await probe.run(configuration: configuration, requestID: UUID()) }
            while probe.ownedPID == nil { await Task.yield() }
            let pid = try XCTUnwrap(probe.ownedPID)
            if cancel { let stopped = await probe.stop(); XCTAssertTrue(stopped) }
            do { _ = try await task.value; XCTFail("must fail") } catch {}
            XCTAssertFalse(probe.hasResources); XCTAssertNotEqual(kill(pid, 0),0)
        }
    }
    func testMainActorRemainsResponsiveWhileProbeImports() async throws {
        let (_,configuration,script) = try setup("slow"), probe = LocalVoiceEngineProbe(scriptURL: script, limits: .init(timeout:2,stopGrace:0.1,killGrace:0.5))
        let task = Task { try await probe.run(configuration:configuration,requestID:UUID()) }
        while probe.ownedPID == nil { await Task.yield() }
        var progressed = false; await Task { @MainActor in progressed = true }.value
        XCTAssertTrue(progressed); _ = try await task.value; XCTAssertFalse(probe.hasResources)
    }
    func testUnconfirmedStopRetainsResourcesAndCanRetry() async throws {
        let (_, configuration, script) = try setup("hang")
        let suppress = ProbeSignalFlag()
        var short = limits(); short.sendSignal = { pid, signal in if !suppress.value { _ = kill(pid, signal) } }
        let probe = LocalVoiceEngineProbe(scriptURL: script, limits: short)
        do { _ = try await probe.run(configuration: configuration, requestID: UUID()); XCTFail("timeout") } catch {}
        XCTAssertTrue(probe.hasResources)
        let pid = try XCTUnwrap(probe.ownedPID)
        suppress.value = false
        let stopped = await probe.stop(); XCTAssertTrue(stopped); XCTAssertFalse(probe.hasResources)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }
    private static let helper = #"""
import argparse,json,os,signal,time
from pathlib import Path
p=argparse.ArgumentParser()
for n in ('engine-root','cache-root','request-id'):p.add_argument('--'+n,required=True)
a=p.parse_args();mode=Path(__file__).stem
if mode=='hang':signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)
if mode=='slow':time.sleep(.2)
if mode=='flood':os.write(1,b'x'*65537);time.sleep(30)
if mode=='stderr':os.write(2,b'x'*1048577);time.sleep(30)
v=dict(v=1,event='checked',requestID=a.request_id,pythonVersion='3.12.14',profile='gpt-sovits-v2proplus-cpu1',sourceCommit='b4570b876f5c086819ba84e3215472733c6a7b70')
if mode=='wrong':v['requestID']='wrong'
if mode=='extra':v['extra']=True
print(json.dumps(v),flush=True)
if mode=='duplicate':print(json.dumps(v),flush=True)
if mode=='nonzero':raise SystemExit(1)
"""#
}

private final class ProbeSignalFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored = true
    var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
