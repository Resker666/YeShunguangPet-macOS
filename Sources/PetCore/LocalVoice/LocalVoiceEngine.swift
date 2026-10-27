import Foundation
import Darwin

public enum LocalVoiceEngineStatus: Equatable, Sendable {
    case unconfigured, configured(profile: String), unavailable(message: String)
}
public struct LocalVoiceEngineConfiguration: Equatable, Sendable {
    public let versionRoot: URL
    public let pythonURL: URL
    public let sourceURL: URL
    public let cacheURL: URL
    public let assetsURL: URL
}
public struct LocalVoiceEngineDescriptor: Equatable, Sendable {
    public static let sourceCommit = "b4570b876f5c086819ba84e3215472733c6a7b70"
    public let versionID: UUID
    public let profile: String
    public static func load(dataRoot: URL) throws -> Self {
        let engine = dataRoot.appendingPathComponent("LocalVoice/Engine")
        let localFD = try LocalVoiceFile.directory(dataRoot.appendingPathComponent("LocalVoice"))
        defer { Darwin.close(localFD) }
        let fd = try LocalVoiceFile.directory(engine)
        defer { Darwin.close(fd) }
        let (data, _) = try LocalVoiceFile.read("current.json", at: fd, maximum: 8192)
        let object = try LocalVoiceObject(StrictJSON.parse(data, maximumBytes: 8192), keys: ["schemaVersion", "versionID", "profile", "architecture", "pythonVersion", "sourceCommit", "python", "source", "assets"])
        guard try object.integer("schemaVersion") == 1, let versionID = UUID(uuidString: try object.string("versionID")),
              try object.string("profile") == LocalVoiceManifest.profile, try object.string("architecture") == "arm64",
              try object.string("pythonVersion") == "3.12", try object.string("sourceCommit") == sourceCommit,
              try object.string("python") == "venv/bin/python", try object.string("source") == "source",
              try object.string("assets") == "engine-assets.json" else { throw LocalVoiceError("本地语音引擎描述无效或版本不支持") }
        return Self(versionID: versionID, profile: LocalVoiceManifest.profile)
    }
    public func resolve(dataRoot: URL) throws -> LocalVoiceEngineConfiguration {
        let local = dataRoot.appendingPathComponent("LocalVoice"), versions = local.appendingPathComponent("Engine/Versions")
        let parent = try LocalVoiceFile.directory(versions)
        defer { Darwin.close(parent) }
        let version = versions.appendingPathComponent(versionID.uuidString)
        let fd = try LocalVoiceFile.directory(version)
        defer { Darwin.close(fd) }
        let source = version.appendingPathComponent("source"), python = version.appendingPathComponent("venv/bin/python")
        let sourceFD = try LocalVoiceFile.directory(source)
        defer { Darwin.close(sourceFD) }
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw LocalVoiceError("本地 Python 环境缺失，请重新准备引擎") }
        _ = try LocalVoiceFile.read("engine-assets.json", at: fd, maximum: 65536)
        return LocalVoiceEngineConfiguration(versionRoot: version, pythonURL: python, sourceURL: source, cacheURL: local.appendingPathComponent("Cache"), assetsURL: version.appendingPathComponent("engine-assets.json"))
    }
    public static func status(dataRoot: URL) -> LocalVoiceEngineStatus {
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("LocalVoice/Engine/current.json").path) else { return .unconfigured }
        #if arch(arm64)
        do { let value = try load(dataRoot: dataRoot); _ = try value.resolve(dataRoot: dataRoot); return .configured(profile: value.profile) }
        catch { return .unavailable(message: "本地语音引擎不可用，请检查或重新准备环境") }
        #else
        return .unavailable(message: "本地引擎首版仅支持 Apple Silicon；此 Mac 可继续使用系统音色")
        #endif
    }
}
