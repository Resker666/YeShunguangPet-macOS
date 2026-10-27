import Foundation
import Darwin

public final class LocalVoiceLibrary {
    public let root: URL
    public init(root: URL) { self.root = root }
    func staging(_ id: UUID) -> URL { root.appendingPathComponent("Staging", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }
    func voice(_ id: UUID) -> URL { root.appendingPathComponent("Voices", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }
    func prepare(_ namespace: String) throws {
        try LocalVoiceFile.ensure(root)
        try LocalVoiceFile.ensure(root.appendingPathComponent(namespace, isDirectory: true))
    }
    public func stage(folder: URL) throws -> StagedLocalVoice {
        guard folder.isFileURL else { throw LocalVoiceError("请选择本地语音文件夹") }
        let id = UUID(), destination = staging(id)
        do {
            try prepare("Staging")
            let (manifest, contentID) = try LocalVoiceFile.snapshot(from: folder, to: destination)
            return StagedLocalVoice(stageID: id, manifest: manifest, contentID: contentID, privateDirectory: destination)
        } catch {
            do { if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) } }
            catch { throw LocalVoiceMutationError(code: .cleanup, cleanupPending: [.init(namespace: .staging, id: id)]) }
            throw error
        }
    }
    func validate(_ staged: StagedLocalVoice) throws {
        guard staged.privateDirectory.standardizedFileURL == staging(staged.stageID).standardizedFileURL else { throw LocalVoiceError("语音快照不属于当前资料目录") }
        let (manifest, contentID) = try LocalVoiceFile.snapshot(from: staged.privateDirectory)
        guard manifest == staged.manifest, contentID == staged.contentID else { throw LocalVoiceError("已预览的语音快照发生变化") }
    }
    public func discard(_ staged: StagedLocalVoice) throws {
        guard staged.privateDirectory.standardizedFileURL == staging(staged.stageID).standardizedFileURL else { throw LocalVoiceError("语音快照目录无效") }
        try remove(.init(namespace: .staging, id: staged.stageID))
    }
    func remove(_ cleanup: LocalVoiceCleanup) throws {
        let namespace = cleanup.namespace == .staging ? "Staging" : "Voices"
        let parent = root.appendingPathComponent(namespace, isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        let rootFD = try LocalVoiceFile.directory(root)
        defer { Darwin.close(rootFD) }
        let parentFD = try LocalVoiceFile.directory(parent)
        defer { Darwin.close(parentFD) }
        let url = cleanup.namespace == .staging ? staging(cleanup.id) : voice(cleanup.id)
        // Removing a final symlink removes the link itself, never its target.
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { try FileManager.default.removeItem(at: url) }
    }
    public func entries(index: LocalVoiceIndex) -> [LocalVoiceLibraryEntry] {
        index.packages.map { registration in
            do { _ = try resolve(libraryID: registration.id, index: index); return LocalVoiceLibraryEntry(registration: registration, issue: nil) }
            catch { return LocalVoiceLibraryEntry(registration: registration, issue: "文件缺失或校验失败，请重新导入") }
        }
    }
    public func resolve(libraryID: UUID, index: LocalVoiceIndex) throws -> ResolvedLocalVoice {
        guard let registration = index.packages.first(where: { $0.id == libraryID }) else { throw LocalVoiceError("音色未登记") }
        let rootFD = try LocalVoiceFile.directory(root)
        defer { Darwin.close(rootFD) }
        let voicesFD = try LocalVoiceFile.directory(root.appendingPathComponent("Voices"))
        defer { Darwin.close(voicesFD) }
        let directory = voice(libraryID)
        let (manifest, contentID) = try LocalVoiceFile.snapshot(from: directory)
        guard contentID == registration.contentID, manifest.id == registration.packageID, manifest.name == registration.name else { throw LocalVoiceError("已登记的音色发生变化，请重新导入") }
        return ResolvedLocalVoice(libraryUUID: libraryID, manifest: manifest, directory: directory)
    }
}
