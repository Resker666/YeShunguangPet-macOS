import Foundation
import CryptoKit
import Darwin

struct LocalVoiceEngineDirectoryIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    init(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LocalVoiceError("引擎包目录不可用") }
        device = info.st_dev; inode = info.st_ino
    }
}
public struct LocalVoiceEnginePreview: Equatable, Sendable {
    public let folder: URL
    public let manifest: LocalVoiceEngineManifest
    public let manifestHash: String
    let rootIdentity, payloadIdentity: LocalVoiceEngineDirectoryIdentity
}

enum LocalVoiceEngineFiles {
    static func directory(_ name: String, at parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalVoiceError("引擎包目录缺失、被替换或是链接") }
        return descriptor
    }
    static func names(at descriptor: Int32, maximum: Int) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw LocalVoiceError("无法读取引擎包目录") }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw LocalVoiceError("无法枚举引擎包目录") }
        defer { closedir(stream) }
        rewinddir(stream)
        var result = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw LocalVoiceError("引擎包目录读取失败") }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
            }
            guard let name else { throw LocalVoiceError("引擎包含非 UTF-8 文件名") }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw LocalVoiceError("引擎包包含额外或过多文件") }
            result.append(name)
        }
        return result
    }
    static func info(_ name: String, at descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { throw LocalVoiceError("引擎包不能包含链接或特殊文件") }
        return info
    }
    static func inspect(payload: Int32, manifest: LocalVoiceEngineManifest, includesManifest: Bool = false) throws {
        let records = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        var children = [String: Set<String>]()
        for file in manifest.files {
            let parts = try LocalVoiceEngineManifest.pathParts(file.path)
            for n in parts.indices { children[parts.prefix(n).joined(separator: "/"), default: []].insert(parts[n]) }
        }
        var found = Set<String>()
        func visit(_ descriptor: Int32, prefix: String) throws {
            let expected = children[prefix] ?? []
            for name in try names(at: descriptor, maximum: expected.count + 1 + (includesManifest && prefix.isEmpty ? 1 : 0)) {
                let value = try info(name, at: descriptor)
                if name == ".DS_Store", value.st_mode & S_IFMT == S_IFREG { continue }
                if includesManifest, prefix.isEmpty, name == "engine.json", value.st_mode & S_IFMT == S_IFREG { continue }
                guard expected.contains(name) else { throw LocalVoiceError("引擎包包含未列入清单的文件或目录") }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if value.st_mode & S_IFMT == S_IFDIR {
                    guard records[path] == nil else { throw LocalVoiceError("引擎包文件变成目录") }
                    let next = try directory(name, at: descriptor); defer { close(next) }
                    try visit(next, prefix: path)
                } else {
                    guard let record = records[path], value.st_size >= 0, UInt64(value.st_size) == record.bytes else { throw LocalVoiceError("引擎包文件大小或类型与清单不一致") }
                    found.insert(path)
                }
            }
        }
        try visit(payload, prefix: "")
        guard found == Set(records.keys) else { throw LocalVoiceError("引擎包缺少清单中的文件") }
    }
}

public enum LocalVoiceEnginePackage {
    public static func preview(folder: URL) throws -> LocalVoiceEnginePreview {
        let root = try LocalVoiceFile.directory(folder); defer { close(root) }
        let identity = try LocalVoiceEngineDirectoryIdentity(root)
        for name in try LocalVoiceEngineFiles.names(at: root, maximum: 3) {
            let info = try LocalVoiceEngineFiles.info(name, at: root)
            guard (name == "engine.json" && info.st_mode & S_IFMT == S_IFREG) ||
                    (name == "payload" && info.st_mode & S_IFMT == S_IFDIR) ||
                    (name == ".DS_Store" && info.st_mode & S_IFMT == S_IFREG) else { throw LocalVoiceError("请选择只包含 engine.json 和 payload 的引擎文件夹") }
        }
        let (data, digest) = try LocalVoiceFile.read("engine.json", at: root, maximum: LocalVoiceEngineManifest.maximumBytes)
        let manifest = try LocalVoiceEngineManifest.decode(data)
        let payload = try LocalVoiceEngineFiles.directory("payload", at: root); defer { close(payload) }
        let payloadIdentity = try LocalVoiceEngineDirectoryIdentity(payload)
        try LocalVoiceEngineFiles.inspect(payload: payload, manifest: manifest)
        let current = try LocalVoiceFile.directory(folder); defer { close(current) }
        guard try LocalVoiceEngineDirectoryIdentity(current) == identity else { throw LocalVoiceError("预览期间引擎包目录被替换") }
        return .init(folder: folder, manifest: manifest, manifestHash: digest, rootIdentity: identity, payloadIdentity: payloadIdentity)
    }
}
