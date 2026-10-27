import Foundation
import PetCore

enum LocalVoiceServiceFixtures {
    static func configuration(root: URL) throws -> LocalVoiceEngineConfiguration {
        let id = UUID(), version = root.appendingPathComponent("LocalVoice/Engine/Versions/" + id.uuidString)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("source"), withIntermediateDirectories: true)
        // /usr/bin/python3 is an xcrun shim and fails when renamed to "python".
        let lookup = Process(), pipe = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); lookup.arguments = ["--find", "python3"]; lookup.standardOutput = pipe
        try lookup.run(); lookup.waitUntilExit()
        let interpreter = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.terminationStatus == 0, interpreter.hasPrefix("/") else { throw LocalVoiceError("test interpreter unavailable") }
        try FileManager.default.createSymbolicLink(at: version.appendingPathComponent("venv/bin/python"), withDestinationURL: URL(fileURLWithPath: interpreter))
        try Data("{\"files\":[]}".utf8).write(to: version.appendingPathComponent("engine-assets.json"))
        let descriptor: [String: Any] = ["schemaVersion": 1, "versionID": id.uuidString, "profile": LocalVoiceManifest.profile, "architecture": "arm64", "pythonVersion": "3.12", "sourceCommit": LocalVoiceEngineDescriptor.sourceCommit, "python": "venv/bin/python", "source": "source", "assets": "engine-assets.json"]
        try JSONSerialization.data(withJSONObject: descriptor).write(to: root.appendingPathComponent("LocalVoice/Engine/current.json"))
        return try LocalVoiceEngineDescriptor.load(dataRoot: root).resolve(dataRoot: root)
    }
    static func voice(root: URL, id: String = "hutao-pilot-e1") throws -> ResolvedLocalVoice {
        let library = LocalVoiceLibrary(root: root.appendingPathComponent("LocalVoice")), store = LocalVoiceIndexStore(root: library.root)
        let stage = try library.stage(folder: LocalVoiceFixtures.folder(root, id: id))
        let commit = try store.apply(.install(stage))
        return try library.resolve(libraryID: commit.installedID!, index: commit.index)
    }
    static func helper(root: URL, mode: String) throws -> URL {
        let url = root.appendingPathComponent(mode + ".py")
        try Data(helperSource.utf8).write(to: url)
        return url
    }
    static let helperSource = #"""
import argparse,json,os,signal,sys,time,wave
from pathlib import Path
p=argparse.ArgumentParser()
for name in ('engine-root','voice-root','work-root','session-id'):p.add_argument('--'+name,required=True)
a=p.parse_args();mode=Path(__file__).stem
def emit(value):
    data=(json.dumps(dict(v=1,sessionID=a.session_id,**value),ensure_ascii=False)+'\n').encode()
    for n in range(0,len(data),3):os.write(1,data[n:n+3])
if mode=='flood':os.write(1,b'x'*65537);time.sleep(30)
if mode=='stderr':os.write(2,b'x'*1048577);time.sleep(30)
if mode=='hang':signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)
if mode=='malformed':os.write(1,b'{bad}\n');time.sleep(30)
emit(dict(event='ready',profile='gpt-sovits-v2proplus-cpu1'))
if mode=='duplicate':emit(dict(event='ready',profile='gpt-sovits-v2proplus-cpu1'))
for line in sys.stdin.buffer:
    c=json.loads(line)
    if c['command']=='shutdown':break
    if mode=='generate-hang':time.sleep(30)
    request=c['requestID'];output=Path(a.work_root)/(request+'.wav')
    if mode=='link':output.symlink_to(Path(a.voice_root)/'reference.wav')
    elif mode!='missing':
        with wave.open(str(output),'wb') as w:
            w.setparams((1,2,32000,0,'NONE','not compressed'));w.writeframes(b'\x01\x00'*3200)
    emit(dict(event='result',requestID='00000000-0000-0000-0000-000000000000' if mode=='wrong-id' else request,sampleRate=32000,frames=3200))
"""#
}

@MainActor final class ControlledLocalVoiceProcess: LocalVoiceProcessDriving {
    var hasResources = false
    var starts = 0, generates = 0, stops = 0
    var speeds = [Double]()
    var holdStart = false, holdGeneration = false, holdStop = false, stopResult = true
    var outputData = LocalVoiceFixtures.pcm(seconds: 0.1)
    var startWaiter: CheckedContinuation<Void, Error>?, generationWaiter: CheckedContinuation<URL, Error>?
    var stopWaiter: CheckedContinuation<Void, Never>?
    var directory: URL?
    func start(configuration: LocalVoiceEngineConfiguration, voice: ResolvedLocalVoice, workDirectory: URL, session: UUID) async throws {
        starts += 1; hasResources = true; directory = workDirectory
        if holdStart { try await withCheckedThrowingContinuation { startWaiter = $0 } }
    }
    func generate(requestID: UUID, text: String, speedFactor: Double) async throws -> URL {
        generates += 1; speeds.append(speedFactor)
        if holdGeneration { return try await withCheckedThrowingContinuation { generationWaiter = $0 } }
        let url = directory!.appendingPathComponent(requestID.uuidString + ".wav")
        try outputData.write(to: url)
        return url
    }
    func stop() async -> Bool {
        stops += 1
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
        if stopResult {
            hasResources = false
            startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
            generationWaiter?.resume(throwing: CancellationError()); generationWaiter = nil
        }
        return stopResult
    }
    func releaseStop() { holdStop = false; stopWaiter?.resume(); stopWaiter = nil }
}

@MainActor final class ControlledLocalVoicePlayer: LocalVoicePlayerDriving {
    var hasResources = false, stopResult = true
    var plays = 0, stops = 0
    var callback: (@MainActor (UUID, LocalVoicePlayerEvent) -> Void)?
    var token: UUID?
    func play(data: Data, token: UUID, onEvent: @escaping @MainActor (UUID, LocalVoicePlayerEvent) -> Void) throws {
        hasResources = true; plays += 1; self.token = token; callback = onEvent; onEvent(token, .started)
    }
    func finish() { hasResources = false; if let token { callback?(token, .finished) } }
    func fail() { hasResources = false; if let token { callback?(token, .failed) } }
    func stop() async -> Bool { stops += 1; if stopResult { hasResources = false }; return stopResult }
}
