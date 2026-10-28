import Foundation
import Darwin
import CryptoKit

final class EngineDirectory {
    let fd: Int32
    let identity: LocalVoiceEngineDirectoryIdentity
    init(_ descriptor: Int32) throws {
        fd = descriptor
        do { identity = try .init(descriptor) } catch { close(descriptor); throw error }
    }
    deinit { close(fd) }
    func child(_ name: String, create: Bool = false) throws -> EngineDirectory {
        if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw LocalVoiceError("无法创建引擎目录") }
        let child = try EngineDirectory(LocalVoiceEngineFiles.directory(name, at: fd))
        if create, fchmod(child.fd, 0o700) != 0 { throw LocalVoiceError("无法设置引擎目录权限") }
        return child
    }
    func check(_ name: String, child: EngineDirectory) throws {
        let info = try LocalVoiceEngineFiles.info(name, at: fd)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == child.identity.device, info.st_ino == child.identity.inode else {
            throw LocalVoiceError("处理期间引擎目录被替换")
        }
    }
}

enum EngineFileIO {
    struct Parent {
        let directory: EngineDirectory
        let name: String
        let chain: [(EngineDirectory, String, EngineDirectory)]
        func validate() throws { for (parent, name, child) in chain { try parent.check(name, child: child) } }
    }
    static func engine(dataRoot: URL, create: Bool) throws -> EngineDirectory {
        if create { try LocalVoiceFile.ensure(dataRoot) }
        let root = try EngineDirectory(LocalVoiceFile.directory(dataRoot))
        let local = try root.child("LocalVoice", create: create)
        let engine = try local.child("Engine", create: create)
        try root.check("LocalVoice", child: local); try local.check("Engine", child: engine)
        return engine
    }
    static func parent(_ relative: String, root: EngineDirectory, create: Bool = false) throws -> Parent {
        let parts = try LocalVoiceEngineManifest.pathParts(relative)
        var current = root, chain = [(EngineDirectory, String, EngineDirectory)]()
        for name in parts.dropLast() {
            let child = try current.child(name, create: create)
            chain.append((current, name, child)); current = child
        }
        return .init(directory: current, name: parts.last!, chain: chain)
    }
    static func unchanged(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
    static func read(_ name: String, at parent: Int32, maximum: Int) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LocalVoiceError("引擎资料缺失或是链接") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximum else { throw LocalVoiceError("引擎资料类型或大小无效") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw LocalVoiceError("引擎资料读取失败") }
            if count == 0 { break }
            guard count <= maximum - data.count else { throw LocalVoiceError("引擎资料读取超限") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        let named = try LocalVoiceEngineFiles.info(name, at: parent)
        guard fstat(fd, &after) == 0, unchanged(before, after), after.st_size == data.count,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino else { throw LocalVoiceError("读取期间引擎资料被替换") }
        return data
    }
    static func optional(_ name: String, at parent: Int32, maximum: Int = 16384) throws -> Data? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw LocalVoiceError("无法检查引擎描述")
        }
        return try read(name, at: parent, maximum: maximum)
    }
    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LocalVoiceError("引擎文件写入失败，可能磁盘空间不足") }
                offset += count
            }
        }
    }
    static func exclusive(_ data: Data, name: String, at parent: Int32) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalVoiceError("无法创建引擎资料副本") }
        var complete = false
        defer { close(fd); if !complete { _ = unlinkat(parent, name, 0) } }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw LocalVoiceError("引擎资料未能完整写入磁盘") }
        complete = true
    }
    static func atomic(_ data: Data, name: String, at parent: Int32, beforeRename: () throws -> Void) throws {
        let temporary = ".engine-" + UUID().uuidString + ".tmp"
        try exclusive(data, name: temporary, at: parent)
        defer { _ = unlinkat(parent, temporary, 0) }
        try beforeRename()
        guard renameat(parent, temporary, parent, name) == 0 else { throw LocalVoiceError("引擎描述未保存，旧引擎保持不变") }
    }
    static func transfer(_ record: LocalVoiceEngineEntry, source: EngineDirectory, target: EngineDirectory?,
                         inspectChunk: (UInt64) throws -> Void, checkCancelled: () -> Bool) throws {
        let from = try parent(record.path, root: source)
        let input = openat(from.directory.fd, from.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw LocalVoiceError("引擎文件缺失或是链接") }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, UInt64(before.st_size) == record.bytes else { throw LocalVoiceError("引擎文件大小与清单不一致") }
        let destination = try target.map { try parent(record.path, root: $0, create: true) }
        var output: Int32 = -1
        if let destination {
            output = openat(destination.directory.fd, destination.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, record.executable ? 0o700 : 0o600)
            guard output >= 0 else { throw LocalVoiceError("引擎副本无法创建") }
        }
        defer { if output >= 0 { close(output) } }
        var total: UInt64 = 0, digest = SHA256(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if checkCancelled() { throw CancellationError() }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw LocalVoiceError("引擎文件读取失败") }
            if count == 0 { break }
            guard UInt64(count) <= record.bytes - total else { throw LocalVoiceError("复制期间引擎文件变大") }
            total += UInt64(count)
            let chunk = Data(buffer.prefix(count)); digest.update(data: chunk)
            if output >= 0 { try writeAll(chunk, to: output) }
            try inspectChunk(total)
        }
        var after = stat()
        let named = try LocalVoiceEngineFiles.info(from.name, at: from.directory.fd)
        guard fstat(input, &after) == 0, unchanged(before, after), total == record.bytes,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == record.sha256 else { throw LocalVoiceError("引擎文件发生变化或摘要校验失败") }
        try from.validate(); try destination?.validate()
        if output >= 0, fchmod(output, record.executable ? 0o700 : 0o600) != 0 { throw LocalVoiceError("引擎副本权限设置失败") }
    }
    static func remove(_ name: String, at parent: Int32, depth: Int = 0) throws {
        guard depth <= 34 else { throw LocalVoiceError("引擎清理目录层级超限") }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }; throw LocalVoiceError("引擎副本无法清理")
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = try EngineDirectory(LocalVoiceEngineFiles.directory(name, at: parent))
            for childName in try LocalVoiceEngineFiles.names(at: child.fd, maximum: 100001) { try remove(childName, at: child.fd, depth: depth + 1) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw LocalVoiceError("引擎目录未清理，可重试") }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw LocalVoiceError("引擎文件未清理，可重试") }
        }
    }
}
