import Foundation
import Darwin

public struct LocalVoiceCleanup: Equatable, Hashable, Sendable {
    public enum Namespace: String, Sendable { case staging, unregisteredVoice }
    public let namespace: Namespace
    public let id: UUID
    public init(namespace: Namespace, id: UUID) { self.namespace = namespace; self.id = id }
}
public enum LocalVoiceMutation: Sendable {
    case install(StagedLocalVoice), bind(characterID: String, libraryID: UUID?), remove(UUID), reset, retryCleanup([LocalVoiceCleanup])
}
public struct LocalVoiceCommit: Equatable, Sendable {
    public let index: LocalVoiceIndex
    public let installedID: UUID?
    public let cleanupPending: [LocalVoiceCleanup]
}
public struct LocalVoiceMutationError: Error, LocalizedError, Sendable {
    public enum Code: Sendable { case protectedIndex, save, cleanup }
    public let code: Code
    public let cleanupPending: [LocalVoiceCleanup]
    public init(code: Code, cleanupPending: [LocalVoiceCleanup] = []) { self.code = code; self.cleanupPending = cleanupPending }
    public var errorDescription: String? {
        switch code {
        case .protectedIndex: "语音库索引受保护，请先备份并重置；系统语音仍可使用。"
        case .save: "语音库未保存，原绑定保持不变；预览副本已保留，可重试保存。"
        case .cleanup: "语音临时文件尚未清理，可重试清理。"
        }
    }
}

public final class LocalVoiceIndexStore {
    public let library: LocalVoiceLibrary
    public var url: URL { library.root.appendingPathComponent("index.json") }
    private let write: (Data, URL) throws -> Void
    private let remove: (URL) throws -> Void
    private var checked = false, protected = false, index = LocalVoiceIndex()
    public init(root: URL, write: ((Data, URL) throws -> Void)? = nil, remove: ((URL) throws -> Void)? = nil) {
        library = LocalVoiceLibrary(root: root)
        self.write = write ?? { try ChatAtomicFile.write($0, to: $1) }
        self.remove = remove ?? { try FileManager.default.removeItem(at: $0) }
    }
    public func load() -> ChatLoadResult<LocalVoiceIndex> {
        if checked { return protected ? .protectedFile(LocalVoiceMutationError(code: .protectedIndex).localizedDescription) : .loaded(index) }
        checked = true
        do {
            guard FileManager.default.fileExists(atPath: library.root.path) else { return .missing }
            let fd = try LocalVoiceFile.directory(library.root); defer { Darwin.close(fd) }
            var info = stat()
            if fstatat(fd, "index.json", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return .missing }
            let (data, _) = try LocalVoiceFile.read("index.json", at: fd, maximum: 65536)
            index = try LocalVoiceIndex.decode(data)
            return .loaded(index)
        } catch {
            protected = true
            return .protectedFile(LocalVoiceMutationError(code: .protectedIndex).localizedDescription)
        }
    }
    private func persist(_ next: LocalVoiceIndex) throws {
        let data = try JSONEncoder().encode(next)
        _ = try LocalVoiceIndex.decode(data)
        try LocalVoiceFile.ensure(library.root)
        try write(data, url)
        index = next
    }
    private func cleanup(_ tokens: [LocalVoiceCleanup]) -> [LocalVoiceCleanup] {
        Array(Set(tokens)).sorted { $0.id.uuidString < $1.id.uuidString }.filter { token in
            if token.namespace == .unregisteredVoice, index.packages.contains(where: { $0.id == token.id }) || index.bindings.values.contains(token.id) { return false }
            let parent = library.root.appendingPathComponent(token.namespace == .staging ? "Staging" : "Voices")
            let target = parent.appendingPathComponent(token.id.uuidString)
            do {
                guard FileManager.default.fileExists(atPath: parent.path) else { return false }
                let fd = try LocalVoiceFile.directory(library.root)
                defer { Darwin.close(fd) }
                let child = try LocalVoiceFile.directory(parent)
                defer { Darwin.close(child) }
                if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil { try remove(target) }
                return false
            } catch { return true }
        }
    }
    public func apply(_ mutation: LocalVoiceMutation) throws -> LocalVoiceCommit {
        _ = load()
        if case .reset = mutation {
            try LocalVoiceFile.ensure(library.root)
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalVoiceMutationError(code: .protectedIndex) }
                try ChatAtomicFile.backup(url, to: url.appendingPathExtension("backup-" + UUID().uuidString))
            }
            try persist(.init()); protected = false
            return .init(index: index, installedID: nil, cleanupPending: [])
        }
        guard !protected else { throw LocalVoiceMutationError(code: .protectedIndex) }
        switch mutation {
        case .install(let staged):
            try library.validate(staged)
            let stageCleanup = LocalVoiceCleanup(namespace: .staging, id: staged.stageID)
            if let existing = index.packages.first(where: { $0.contentID == staged.contentID }) {
                _ = try library.resolve(libraryID: existing.id, index: index)
                return .init(index: index, installedID: existing.id, cleanupPending: cleanup([stageCleanup]))
            }
            let id = UUID()
            let registration = LocalVoiceRegistration(id: id, packageID: staged.manifest.id, name: staged.manifest.name, contentID: staged.contentID)
            let next = try LocalVoiceIndex(packages: index.packages + [registration], bindings: index.bindings)
            try library.prepare("Voices")
            let abandoned = LocalVoiceCleanup(namespace: .unregisteredVoice, id: id)
            do {
                let (_, contentID) = try LocalVoiceFile.snapshot(from: staged.privateDirectory, to: library.voice(id))
                guard contentID == staged.contentID else { throw LocalVoiceError("语音快照发生变化") }
                try persist(next)
            } catch { throw LocalVoiceMutationError(code: .save, cleanupPending: cleanup([abandoned])) }
            return .init(index: index, installedID: id, cleanupPending: cleanup([stageCleanup]))
        case .bind(let role, let id):
            if let id { _ = try library.resolve(libraryID: id, index: index) }
            let next = try index.binding(characterID: role, to: id)
            do { try persist(next) } catch { throw LocalVoiceMutationError(code: .save) }
            return .init(index: index, installedID: nil, cleanupPending: [])
        case .remove(let id):
            guard !index.bindings.values.contains(id) else { throw LocalVoiceError("此音色仍有角色使用，请先取消绑定") }
            let next = try LocalVoiceIndex(packages: index.packages.filter { $0.id != id }, bindings: index.bindings)
            do { try persist(next) } catch { throw LocalVoiceMutationError(code: .save) }
            return .init(index: index, installedID: nil, cleanupPending: cleanup([.init(namespace: .unregisteredVoice, id: id)]))
        case .retryCleanup(let tokens): return .init(index: index, installedID: nil, cleanupPending: cleanup(tokens))
        case .reset: preconditionFailure("handled above")
        }
    }
}
