import Foundation
import Darwin

enum ChatAtomicFile {
    static func directory(_ url: URL, create: Bool) throws {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SkinError("聊天目录不可用。") }
            if create { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            if create { try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes) else {
            throw SkinError("聊天资料类型或大小无效。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maximumBytes {
            let part = try handle.read(upToCount: min(65536, maximumBytes + 1 - result.count)) ?? Data()
            if part.isEmpty { break }
            result.append(part)
        }
        guard result.count <= maximumBytes else { throw SkinError("聊天资料超过允许大小。") }
        return result
    }

    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent(), create: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".chat-" + UUID().uuidString + ".tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SkinError("聊天资料未能保存，原文件保持不变。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw SkinError("聊天资料未能保存，原文件保持不变。") }
    }

    static func backup(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
