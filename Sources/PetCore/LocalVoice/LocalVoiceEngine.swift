import Foundation
import CryptoKit
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
    public let schemaVersion: Int
    public let versionID: UUID
    public let profile: String
    public let packageID, packageVersion, packageName, manifestSHA256: String?
    private static let baseKeys: Set<String> = ["schemaVersion", "versionID", "profile", "architecture", "pythonVersion", "sourceCommit", "python", "source", "assets"]
    static func portable(_ candidate: LocalVoiceEngineCandidate) -> Self {
        let manifest = candidate.preview.manifest
        return .init(schemaVersion: 2, versionID: candidate.versionID, profile: manifest.profile, packageID: manifest.id, packageVersion: manifest.version, packageName: manifest.name, manifestSHA256: candidate.preview.manifestHash)
    }
    func encoded() throws -> Data {
        var values: [String: Any] = ["schemaVersion": schemaVersion, "versionID": versionID.uuidString, "profile": profile, "architecture": "arm64", "pythonVersion": "3.12", "sourceCommit": Self.sourceCommit, "python": schemaVersion == 1 ? "venv/bin/python" : "runtime/bin/python3.12", "source": "source", "assets": "engine-assets.json"]
        if schemaVersion == 2 {
            values["packageID"] = packageID; values["packageVersion"] = packageVersion
            values["packageName"] = packageName; values["manifestSHA256"] = manifestSHA256
        }
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }
    public static func load(dataRoot: URL) throws -> Self {
        let engine = try EngineFileIO.engine(dataRoot: dataRoot, create: false)
        let data = try EngineFileIO.read("current.json", at: engine.fd, maximum: 16384)
        let parsed = try StrictJSON.parse(data, maximumBytes: 16384)
        guard case .object(let values) = parsed, case .number(let number) = values["schemaVersion"], let schema = Int(number), [1, 2].contains(schema) else { throw LocalVoiceError("本地语音引擎描述无效或版本不支持") }
        let keys = schema == 1 ? baseKeys : baseKeys.union(["packageID", "packageVersion", "packageName", "manifestSHA256"])
        let object = try LocalVoiceObject(parsed, keys: keys)
        guard let versionID = UUID(uuidString: try object.string("versionID")), try object.string("profile") == LocalVoiceManifest.profile,
              try object.string("architecture") == "arm64", try object.string("pythonVersion") == "3.12", try object.string("sourceCommit") == sourceCommit,
              try object.string("python") == (schema == 1 ? "venv/bin/python" : "runtime/bin/python3.12"), try object.string("source") == "source", try object.string("assets") == "engine-assets.json" else { throw LocalVoiceError("本地语音引擎描述无效或版本不支持") }
        var id: String?, version: String?, name: String?, digest: String?
        if schema == 2 {
            id = try object.string("packageID"); version = try object.string("packageVersion")
            name = try object.string("packageName"); digest = try object.string("manifestSHA256")
            guard ManifestDecoder.isValidID(id!), version!.utf8.count <= 40, let release = ReleaseVersion(tag: version!), release.description == version!, LocalVoiceObject.text(name!, maximum: 80), LocalVoiceObject.digest(digest!) else { throw LocalVoiceError("本地引擎包身份无效") }
        }
        return .init(schemaVersion: schema, versionID: versionID, profile: LocalVoiceManifest.profile, packageID: id, packageVersion: version, packageName: name, manifestSHA256: digest)
    }
    public func resolve(dataRoot: URL) throws -> LocalVoiceEngineConfiguration {
        let engine = try EngineFileIO.engine(dataRoot: dataRoot, create: false), versions = try engine.child("Versions"), directory = try versions.child(versionID.uuidString)
        let local = dataRoot.appendingPathComponent("LocalVoice"), version = local.appendingPathComponent("Engine/Versions/" + versionID.uuidString)
        let source = try directory.child("source")
        try engine.check("Versions", child: versions); try versions.check(versionID.uuidString, child: directory); try directory.check("source", child: source)
        let python: URL
        if schemaVersion == 2 {
            let raw = try EngineFileIO.read("engine.json", at: directory.fd, maximum: LocalVoiceEngineManifest.maximumBytes)
            let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
            let manifest = try LocalVoiceEngineManifest.decode(raw)
            guard hash == manifestSHA256, manifest.id == packageID, manifest.version == packageVersion, manifest.name == packageName, manifest.profile == profile else { throw LocalVoiceError("本地引擎清单身份不一致，请修复引擎") }
            let runtime = try directory.child("runtime"), bin = try runtime.child("bin")
            let info = try LocalVoiceEngineFiles.info("python3.12", at: bin.fd)
            guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o100 != 0,
                  manifest.files.contains(where: { $0.path == "runtime/bin/python3.12" && $0.bytes == UInt64(info.st_size) }) else { throw LocalVoiceError("本地 Python 环境无效，请修复引擎") }
            try directory.check("runtime", child: runtime); try runtime.check("bin", child: bin)
            python = version.appendingPathComponent("runtime/bin/python3.12")
        } else {
            // Legacy preparation intentionally linked its final Python to Homebrew.
            let venv = try directory.child("venv"), bin = try venv.child("bin")
            try directory.check("venv", child: venv); try venv.check("bin", child: bin)
            python = version.appendingPathComponent("venv/bin/python")
            guard FileManager.default.isExecutableFile(atPath: python.path) else { throw LocalVoiceError("本地 Python 环境缺失，请重新准备引擎") }
        }
        _ = try EngineFileIO.read("engine-assets.json", at: directory.fd, maximum: 65536)
        return .init(versionRoot: version, pythonURL: python, sourceURL: version.appendingPathComponent("source"), cacheURL: local.appendingPathComponent("Cache"), assetsURL: version.appendingPathComponent("engine-assets.json"))
    }
    public static func status(dataRoot: URL) -> LocalVoiceEngineStatus {
        var info = stat()
        if lstat(dataRoot.appendingPathComponent("LocalVoice/Engine/current.json").path, &info) != 0, errno == ENOENT { return .unconfigured }
        #if arch(arm64)
        do { let value = try load(dataRoot: dataRoot); _ = try value.resolve(dataRoot: dataRoot); return .configured(profile: value.profile) }
        catch { return .unavailable(message: "本地语音引擎不可用，请检查或重新准备环境") }
        #else
        return .unavailable(message: "本地引擎首版仅支持 Apple Silicon；此 Mac 可继续使用系统音色")
        #endif
    }
}
