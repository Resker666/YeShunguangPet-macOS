import Foundation
import CryptoKit
import Darwin

public struct StagedLocalVoice: Equatable, Sendable {
    public let stageID: UUID
    public let manifest: LocalVoiceManifest
    public let contentID: String
    public let privateDirectory: URL
}
public struct ResolvedLocalVoice: Equatable, Sendable {
    public let libraryUUID: UUID
    public let manifest: LocalVoiceManifest
    public let directory: URL
}
public struct LocalVoiceLibraryEntry: Equatable, Sendable, Identifiable {
    public let registration: LocalVoiceRegistration
    public let issue: String?
    public var id: UUID { registration.id }
}

// A selected directory may have system aliases in its parents (/var, /tmp),
// but neither its final component nor any package file may be a link.
enum LocalVoiceFile {
    static func directory(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalVoiceError("语音目录不可用或是链接") }
        return fd
    }
    static func ensure(_ url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = try directory(url); defer { Darwin.close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw LocalVoiceError("语音目录权限不可用") }
    }
    static func read(_ filename: String, at directory: Int32, maximum: Int, expected: Int? = nil,
                     output: URL? = nil, collect: Bool = true, inspectChunk: ((Int) throws -> Void)? = nil) throws -> (Data, String) {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LocalVoiceError("语音文件缺失或是链接") }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximum, expected.map({ before.st_size == $0 }) ?? true else {
            throw LocalVoiceError("语音文件类型或大小无效")
        }
        var target: FileHandle?
        if let output {
            let out = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw LocalVoiceError("语音快照无法创建") }
            target = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        }
        defer { try? target?.close() }
        var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), total = 0, data = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw LocalVoiceError("语音文件读取失败") }
            if count == 0 { break }
            guard count <= maximum - total else { throw LocalVoiceError("读取中的语音文件超出上限") }
            total += count
            let chunk = Data(buffer.prefix(count)); digest.update(data: chunk)
            if let target { try target.write(contentsOf: chunk) } else if collect { data.append(chunk) }
            try inspectChunk?(total)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == total, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw LocalVoiceError("读取期间语音文件发生变化，请重新预览")
        }
        return (data, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func snapshot(from source: URL, to destination: URL? = nil) throws -> (LocalVoiceManifest, String) {
        let fd = try directory(source); defer { Darwin.close(fd) }
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: source.path)
        let expected: Set<String> = ["voice.json", "s2.pth", "reference.wav"]
        guard Set(names).subtracting([".DS_Store"]) == expected else { throw LocalVoiceError("语音包只允许 voice.json、s2.pth 和 reference.wav") }
        for name in names {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { throw LocalVoiceError("语音包不能包含目录、链接或特殊文件") }
        }
        let (manifestData, manifestHash) = try read("voice.json", at: fd, maximum: 16384)
        let manifest = try LocalVoiceManifest.decode(manifestData)
        if let destination { try ensure(destination) }
        let (_, modelHash) = try read("s2.pth", at: fd, maximum: 268435456, expected: manifest.model.bytes, output: destination?.appendingPathComponent("s2.pth"), collect: false)
        let (reference, referenceHash) = try read("reference.wav", at: fd, maximum: 1048576, expected: manifest.reference.bytes)
        guard modelHash == manifest.model.sha256, referenceHash == manifest.reference.sha256 else { throw LocalVoiceError("语音包校验失败，文件与清单不一致") }
        _ = try LocalVoicePCM.validate(reference, maximumBytes: 1048576, minimumSeconds: 3, maximumSeconds: 10)
        guard Set(try manager.contentsOfDirectory(atPath: source.path)) == Set(names) else { throw LocalVoiceError("预览期间目录发生变化") }
        // Confirm that the path still names the directory whose files we read.
        let current = try directory(source); defer { Darwin.close(current) }
        var initial = stat(), final = stat()
        guard fstat(fd, &initial) == 0, fstat(current, &final) == 0, initial.st_dev == final.st_dev, initial.st_ino == final.st_ino else { throw LocalVoiceError("预览期间目录被替换") }
        if let destination {
            try ChatAtomicFile.write(manifestData, to: destination.appendingPathComponent("voice.json"))
            try ChatAtomicFile.write(reference, to: destination.appendingPathComponent("reference.wav"))
        }
        let joined = [manifestHash, modelHash, referenceHash].joined(separator: "\n")
        let contentID = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return (manifest, contentID)
    }
}
