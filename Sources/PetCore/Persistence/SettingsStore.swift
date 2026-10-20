import Foundation
import Darwin

public enum SettingsLoadResult { case missing, loaded(PlacementSnapshot), protectedFile(message: String) }
public final class SettingsStore {
    private struct Configuration: Codable { let schemaVersion: Int; let placement: PlacementSnapshot }
    public let url: URL
    private var checked=false, blocked=false
    private let write: (Data,URL) throws -> Void
    private let backup: (URL,URL) throws -> Void
    public init(url: URL, write: @escaping (Data,URL) throws -> Void = { try $0.write(to:$1,options:.atomic) }, backup: @escaping (URL,URL) throws -> Void = { try FileManager.default.moveItem(at:$0,to:$1) }) { self.url=url; self.write=write; self.backup=backup }
    public func load() -> SettingsLoadResult {
        checked=true
        var info=stat()
        if lstat(url.path,&info) != 0 && errno==ENOENT { blocked=false; return .missing }
        do {
            let data=try SkinLoader.readFile(at:url,maximumBytes:65536)
            guard case .object(let values)=try StrictJSON.parse(data),case .number("1")=values["schemaVersion"] else { throw SkinError("配置版本无效或尚不支持") }
            let config=try JSONDecoder().decode(Configuration.self,from:data)
            guard config.schemaVersion==1,config.placement.isValid else { throw SkinError("配置中的位置无效") }
            blocked=false; return .loaded(config.placement)
        } catch { blocked=true; return .protectedFile(message:"配置无法读取，原文件已保留：\(error.localizedDescription)") }
    }
    public func save(_ placement: PlacementSnapshot) throws {
        if !checked { _=load() }
        guard !blocked else { throw SkinError("原配置受保护，请先备份并重置") }
        guard placement.isValid else { throw SkinError("位置无效，未保存") }
        let data=try JSONEncoder().encode(Configuration(schemaVersion:1,placement:placement))
        guard data.count<=65536 else { throw SkinError("配置超过 64 KiB") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try write(data,url)
    }
    public func backupAndReset() throws {
        var info=stat()
        if lstat(url.path,&info)==0 {
            let destination=url.deletingLastPathComponent().appendingPathComponent("settings.backup-\(UUID().uuidString).json")
            try backup(url,destination)
        } else if errno != ENOENT { throw SkinError("无法安全检查原配置") }
        blocked=false; checked=true
    }
}
