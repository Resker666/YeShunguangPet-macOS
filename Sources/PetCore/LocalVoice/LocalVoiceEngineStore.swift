import Foundation
import CryptoKit
import Darwin

public enum LocalVoiceEngineWorkPhase: Equatable, Sendable { case copying, verifying }
public struct LocalVoiceEngineProgress: Equatable, Sendable {
    public let phase: LocalVoiceEngineWorkPhase
    public let completedBytes, totalBytes: UInt64
    public init(phase: LocalVoiceEngineWorkPhase, completedBytes: UInt64, totalBytes: UInt64) {
        self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}
public struct LocalVoiceEngineCandidate: Equatable, Sendable {
    public let versionID: UUID
    public let preview: LocalVoiceEnginePreview
    public let previousDescriptor: Data?
    public let configuration: LocalVoiceEngineConfiguration
    let directoryIdentity: LocalVoiceEngineDirectoryIdentity
}

// The worker owns the lease across copy/probe/commit; it never transfers the
// lease to the MainActor or releases it concurrently with a store operation.
public final class LocalVoiceEngineLease {
    fileprivate let root: URL, engine: EngineDirectory, versions: EngineDirectory
    private var descriptor: Int32
    fileprivate init(root: URL, engine: EngineDirectory, versions: EngineDirectory, descriptor: Int32) {
        self.root = root; self.engine = engine; self.versions = versions; self.descriptor = descriptor
    }
    public func release() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    deinit { release() }
    fileprivate func validate(dataRoot: URL) throws {
        guard descriptor >= 0, root.standardizedFileURL == dataRoot.standardizedFileURL,
              try EngineFileIO.engine(dataRoot: dataRoot, create: false).identity == engine.identity else { throw LocalVoiceError("引擎安装锁已失效或目录被替换") }
        try engine.check("Versions", child: versions)
        var held = stat()
        let named = try LocalVoiceEngineFiles.info("use.lock", at: engine.fd)
        guard fstat(descriptor, &held) == 0, held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw LocalVoiceError("引擎锁文件被替换") }
    }
}

public final class LocalVoiceEngineStore: Sendable {
    public struct Hooks: Sendable {
        public var availableBytes: @Sendable (URL) throws -> UInt64
        public var inspectChunk: @Sendable (String, UInt64) throws -> Void
        public var beforeCommit: @Sendable () throws -> Void
        public var afterCommit: @Sendable () -> Void
        public var beforeBackup: @Sendable () throws -> Void
        public var beforeRemove: @Sendable (URL) throws -> Void
        public init(availableBytes: @escaping @Sendable (URL) throws -> UInt64 = { url in
            guard let number = try FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber else { throw LocalVoiceError("无法检查引擎安装空间") }
            return number.uint64Value
        }, inspectChunk: @escaping @Sendable (String, UInt64) throws -> Void = { _, _ in },
                    beforeCommit: @escaping @Sendable () throws -> Void = {}, afterCommit: @escaping @Sendable () -> Void = {},
                    beforeBackup: @escaping @Sendable () throws -> Void = {}, beforeRemove: @escaping @Sendable (URL) throws -> Void = { _ in }) {
            self.availableBytes = availableBytes; self.inspectChunk = inspectChunk; self.beforeCommit = beforeCommit
            self.afterCommit = afterCommit; self.beforeBackup = beforeBackup; self.beforeRemove = beforeRemove
        }
        public static var live: Self { .init() }
    }
    public let dataRoot: URL
    private let hooks: Hooks
    public init(dataRoot: URL, hooks: Hooks = .live) { self.dataRoot = dataRoot; self.hooks = hooks }
    public func acquire() throws -> LocalVoiceEngineLease {
        let engine = try EngineFileIO.engine(dataRoot: dataRoot, create: true)
        let descriptor = openat(engine.fd, "use.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalVoiceError("无法打开引擎安装锁") }
        var success = false
        defer { if !success { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LocalVoiceError("本地引擎正在使用或安装中，请先停止后重试") }
        let versions = try engine.child("Versions", create: true)
        let lease = LocalVoiceEngineLease(root: dataRoot, engine: engine, versions: versions, descriptor: descriptor)
        success = true; try lease.validate(dataRoot: dataRoot)
        return lease
    }
    public func begin(_ preview: LocalVoiceEnginePreview, lease: LocalVoiceEngineLease) throws -> LocalVoiceEngineCandidate {
        try lease.validate(dataRoot: dataRoot)
        let refreshed = try LocalVoiceEnginePackage.preview(folder: preview.folder)
        guard refreshed == preview else { throw LocalVoiceError("预览后引擎包已改变，请重新选择") }
        let required = preview.manifest.totalBytes + max(256 * 1024 * 1024, (preview.manifest.totalBytes + 9) / 10)
        guard try hooks.availableBytes(dataRoot) >= required else { throw LocalVoiceError("磁盘空间不足，需要同时保留新旧引擎及安装余量") }
        let previous = try EngineFileIO.optional("current.json", at: lease.engine.fd)
        let id = UUID(), name = id.uuidString
        guard mkdirat(lease.versions.fd, name, 0o700) == 0 else { throw LocalVoiceError("新引擎版本目录无法创建") }
        let directory = try lease.versions.child(name)
        let configuration = LocalVoiceEngineConfiguration(versionRoot: versionURL(id), pythonURL: versionURL(id).appendingPathComponent("runtime/bin/python3.12"), sourceURL: versionURL(id).appendingPathComponent("source"), cacheURL: dataRoot.appendingPathComponent("LocalVoice/Cache"), assetsURL: versionURL(id).appendingPathComponent("engine-assets.json"))
        return .init(versionID: id, preview: preview, previousDescriptor: previous, configuration: configuration, directoryIdentity: directory.identity)
    }
    private func versionURL(_ id: UUID) -> URL { dataRoot.appendingPathComponent("LocalVoice/Engine/Versions/" + id.uuidString) }
    private func openCandidate(_ candidate: LocalVoiceEngineCandidate, engine: EngineDirectory) throws -> EngineDirectory {
        guard candidate.configuration.versionRoot == versionURL(candidate.versionID) else { throw LocalVoiceError("引擎候选目录不属于此安装位置") }
        let versions = try engine.child("Versions"), version = try versions.child(candidate.versionID.uuidString)
        guard version.identity == candidate.directoryIdentity else { throw LocalVoiceError("引擎候选目录被替换") }
        try engine.check("Versions", child: versions); try versions.check(candidate.versionID.uuidString, child: version)
        return version
    }
    public func copy(_ candidate: LocalVoiceEngineCandidate, progress: @Sendable (LocalVoiceEngineProgress) -> Void, checkCancelled: @Sendable () -> Bool) throws {
        if checkCancelled() { throw CancellationError() }
        let engine = try EngineFileIO.engine(dataRoot: dataRoot, create: false), destination = try openCandidate(candidate, engine: engine)
        let root = try EngineDirectory(LocalVoiceFile.directory(candidate.preview.folder))
        let source = try root.child("payload")
        guard root.identity == candidate.preview.rootIdentity, source.identity == candidate.preview.payloadIdentity else { throw LocalVoiceError("引擎包目录被替换") }
        let manifestData = try EngineFileIO.read("engine.json", at: root.fd, maximum: LocalVoiceEngineManifest.maximumBytes)
        guard hash(manifestData) == candidate.preview.manifestHash else { throw LocalVoiceError("确认后引擎清单发生变化") }
        try LocalVoiceEngineFiles.inspect(payload: source.fd, manifest: candidate.preview.manifest)
        var completed: UInt64 = 0
        for record in candidate.preview.manifest.files {
            let base = completed
            try EngineFileIO.transfer(record, source: source, target: destination, inspectChunk: { count in
                try hooks.inspectChunk(record.path, count)
                progress(.init(phase: .copying, completedBytes: base + count, totalBytes: candidate.preview.manifest.totalBytes))
            }, checkCancelled: checkCancelled)
            completed += record.bytes
        }
        try root.check("payload", child: source)
        guard try LocalVoiceEnginePackage.preview(folder: candidate.preview.folder) == candidate.preview else { throw LocalVoiceError("复制期间引擎包目录或清单改变") }
        try EngineFileIO.exclusive(manifestData, name: "engine.json", at: destination.fd)
        try verify(candidate, progress: progress, checkCancelled: checkCancelled)
    }
    public func verify(_ candidate: LocalVoiceEngineCandidate, progress: @Sendable (LocalVoiceEngineProgress) -> Void = { _ in }, checkCancelled: @Sendable () -> Bool = { false }) throws {
        let engine = try EngineFileIO.engine(dataRoot: dataRoot, create: false), directory = try openCandidate(candidate, engine: engine)
        let data = try EngineFileIO.read("engine.json", at: directory.fd, maximum: LocalVoiceEngineManifest.maximumBytes)
        guard hash(data) == candidate.preview.manifestHash else { throw LocalVoiceError("候选引擎清单校验失败") }
        try LocalVoiceEngineFiles.inspect(payload: directory.fd, manifest: candidate.preview.manifest, includesManifest: true)
        var completed: UInt64 = 0
        for record in candidate.preview.manifest.files {
            let base = completed
            try EngineFileIO.transfer(record, source: directory, target: nil, inspectChunk: { count in
                progress(.init(phase: .verifying, completedBytes: base + count, totalBytes: candidate.preview.manifest.totalBytes))
            }, checkCancelled: checkCancelled)
            completed += record.bytes
        }
        _ = try openCandidate(candidate, engine: engine)
        if checkCancelled() { throw CancellationError() }
    }
    public func activate(_ candidate: LocalVoiceEngineCandidate, lease: LocalVoiceEngineLease, checkCancelled: @Sendable () -> Bool) throws -> LocalVoiceEngineDescriptor {
        try lease.validate(dataRoot: dataRoot)
        guard try EngineFileIO.optional("current.json", at: lease.engine.fd) == candidate.previousDescriptor else { throw LocalVoiceError("当前引擎已被其他进程改变，请重新选择安装；不会覆盖新状态") }
        try verify(candidate, checkCancelled: checkCancelled)
        if let previous = candidate.previousDescriptor {
            let backups = try lease.engine.child("Backups", create: true), filename = "current-" + candidate.versionID.uuidString + ".json"
            if let existing = try EngineFileIO.optional(filename, at: backups.fd) {
                guard existing == previous else { throw LocalVoiceError("旧引擎描述备份不一致，切换已取消") }
            } else { try hooks.beforeBackup(); try EngineFileIO.exclusive(previous, name: filename, at: backups.fd) }
        }
        let descriptor = LocalVoiceEngineDescriptor.portable(candidate)
        try EngineFileIO.atomic(descriptor.encoded(), name: "current.json", at: lease.engine.fd) {
            try hooks.beforeCommit()
            if checkCancelled() { throw CancellationError() }
            try lease.validate(dataRoot: dataRoot)
            guard try EngineFileIO.optional("current.json", at: lease.engine.fd) == candidate.previousDescriptor else { throw LocalVoiceError("提交前当前引擎改变，未覆盖其他状态") }
        }
        // rename is the linearization point. A late cancel cannot undo success.
        hooks.afterCommit()
        return descriptor
    }
    public func discard(versionID: UUID, lease: LocalVoiceEngineLease) throws {
        try lease.validate(dataRoot: dataRoot)
        if let current = try EngineFileIO.optional("current.json", at: lease.engine.fd),
           String(decoding: current, as: UTF8.self).range(of: versionID.uuidString, options: .caseInsensitive) != nil { throw LocalVoiceError("当前引擎或受保护描述仍引用此版本，不能清理") }
        try hooks.beforeRemove(versionURL(versionID))
        try lease.validate(dataRoot: dataRoot)
        try EngineFileIO.remove(versionID.uuidString, at: lease.versions.fd)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
