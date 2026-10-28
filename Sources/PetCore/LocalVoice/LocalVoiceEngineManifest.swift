import Foundation
import CryptoKit

public struct LocalVoiceEngineEntry: Equatable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let sha256: String
    public let executable: Bool
}

public struct LocalVoiceEngineManifest: Equatable, Sendable {
    private static let emptyFileDigest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumFileBytes: UInt64 = 2 * 1024 * 1024 * 1024
    public static let maximumTotalBytes: UInt64 = 12 * 1024 * 1024 * 1024
    public let schemaVersion: Int
    public let id, version, name, architecture, minimumOS, pythonVersion, profile, sourceCommit: String
    public let files: [LocalVoiceEngineEntry]
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.bytes } }

    static func pathParts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.utf8.count <= 4096, !path.contains("\\"), (1...32).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".DS_Store" && $0.utf8.count <= 255 &&
            !$0.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }) else { throw LocalVoiceError("引擎包含无效或越界路径") }
        return parts
    }
    static func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX")) }
    private static func stableVersion(_ value: String) -> ReleaseVersion? {
        guard value.utf8.count <= 40, let version = ReleaseVersion(tag: value), version.description == value else { return nil }
        return version
    }
    public static func decode(_ data: Data) throws -> Self {
        let object = try LocalVoiceObject(StrictJSON.parse(data, maximumBytes: maximumBytes), keys: ["schemaVersion", "id", "version", "name", "architecture", "minimumOS", "pythonVersion", "profile", "sourceCommit", "files"])
        let schema = try object.integer("schemaVersion"), id = try object.string("id"), version = try object.string("version"), name = try object.string("name")
        let architecture = try object.string("architecture"), minimum = try object.string("minimumOS"), python = try object.string("pythonVersion")
        let profile = try object.string("profile"), commit = try object.string("sourceCommit")
        guard schema == 1, ManifestDecoder.isValidID(id), stableVersion(version) != nil, LocalVoiceObject.text(name, maximum: 80),
              architecture == "arm64", minimum == "14.0", let pythonNumber = stableVersion(python), pythonNumber.major == 3, pythonNumber.minor == 12,
              profile == LocalVoiceManifest.profile, commit == LocalVoiceEngineDescriptor.sourceCommit,
              case .array(let rows) = object.values["files"], !rows.isEmpty, rows.count <= 100000 else {
            throw LocalVoiceError("引擎包版本、平台、资源清单或名称不受支持")
        }
        var files = [LocalVoiceEngineEntry](), paths = Set<String>(), directories = Set<String>(), total: UInt64 = 0
        for row in rows {
            let value = try LocalVoiceObject(row, keys: ["path", "bytes", "sha256", "executable"])
            let path = try value.string("path"), signedBytes = try value.integer("bytes"), digest = try value.string("sha256")
            let parts = try pathParts(path), key = pathKey(path)
            guard signedBytes >= 0, UInt64(signedBytes) <= maximumFileBytes, LocalVoiceObject.digest(digest),
                  (path == "engine-assets.json" || (["runtime", "source", "licenses"].contains(parts[0]) && parts.count > 1)),
                  (signedBytes != 0 || digest == emptyFileDigest),
                  case .bool(let executable) = value.values["executable"], paths.insert(key).inserted else {
                throw LocalVoiceError("引擎包文件记录重复或大小、摘要、权限无效")
            }
            let bytes = UInt64(signedBytes)
            guard bytes <= maximumTotalBytes - total else { throw LocalVoiceError("引擎包展开总量超过 12 GiB") }
            total += bytes
            if parts.count > 1 { for n in 1..<parts.count { directories.insert(pathKey(parts.prefix(n).joined(separator: "/"))) } }
            files.append(.init(path: path, bytes: bytes, sha256: digest, executable: executable))
        }
        guard paths.isDisjoint(with: directories), let pythonFile = files.first(where: { $0.path == "runtime/bin/python3.12" }), pythonFile.bytes > 0, pythonFile.executable,
              files.contains(where: { $0.path == "engine-assets.json" && $0.bytes > 0 && $0.bytes <= 65536 }),
              files.contains(where: { $0.path.hasPrefix("source/") }), files.contains(where: { $0.path.hasPrefix("licenses/") }) else {
            throw LocalVoiceError("引擎包缺少固定运行文件或存在文件与目录冲突")
        }
        return Self(schemaVersion: schema, id: id, version: version, name: name, architecture: architecture, minimumOS: minimum,
                    pythonVersion: python, profile: profile, sourceCommit: commit, files: files)
    }
}
