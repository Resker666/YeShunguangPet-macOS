import Foundation
import Darwin

public struct PetPreferences: Codable, Equatable {
    public var scale: Double
    public var alwaysOnTop: Bool
    public var lookAtMouse: Bool
    public var automaticActions: Bool
    public var automaticActionIntervalSeconds: Int
    public var desktopRoaming: Bool
    public var roamIntervalSeconds: Int
    public init(scale: Double = 1, alwaysOnTop: Bool = true, lookAtMouse: Bool = true, automaticActions: Bool = false, automaticActionIntervalSeconds: Int = 60, desktopRoaming: Bool = false, roamIntervalSeconds: Int = 75) {
        self.scale=scale; self.alwaysOnTop=alwaysOnTop; self.lookAtMouse=lookAtMouse
        self.automaticActions=automaticActions; self.automaticActionIntervalSeconds=automaticActionIntervalSeconds
        self.desktopRoaming=desktopRoaming;self.roamIntervalSeconds=roamIntervalSeconds
    }
    public var isValid: Bool { scale.isFinite && (0.5...2).contains(scale) && (15...120).contains(automaticActionIntervalSeconds) && (20...180).contains(roamIntervalSeconds) }
}
public struct PetSettings: Equatable {
    public let placement: PlacementSnapshot?
    public let preferences: PetPreferences
    public let selectedSkinID: String?
    public init(placement: PlacementSnapshot?, preferences: PetPreferences = .init(), selectedSkinID: String? = nil) { self.placement=placement; self.preferences=preferences; self.selectedSkinID=selectedSkinID }
    public var isValid: Bool { (placement?.isValid ?? true) && preferences.isValid && (selectedSkinID.map(SkinLibrary.isValidID) ?? true) }
}
public enum SettingsLoadResult { case missing, loaded(PetSettings), protectedFile(message: String) }
public final class SettingsStore {
    private struct LegacyConfiguration: Decodable { let placement: PlacementSnapshot }
    private struct OldPreferences: Decodable { let scale: Double; let alwaysOnTop: Bool }
    private struct OldConfiguration: Decodable { let schemaVersion: Int; let placement: PlacementSnapshot?; let preferences: OldPreferences; let selectedSkinID: String? }
    private struct GazePreferences: Decodable { let scale: Double; let alwaysOnTop: Bool; let lookAtMouse: Bool }
    private struct GazeConfiguration: Decodable { let placement: PlacementSnapshot?; let preferences: GazePreferences; let selectedSkinID: String? }
    private struct ActionPreferences: Decodable { let scale: Double;let alwaysOnTop,lookAtMouse,automaticActions: Bool;let automaticActionIntervalSeconds: Int }
    private struct ActionConfiguration: Decodable { let placement: PlacementSnapshot?;let preferences: ActionPreferences;let selectedSkinID: String? }
    private struct Configuration: Codable { let schemaVersion: Int; let placement: PlacementSnapshot?; let preferences: PetPreferences; let selectedSkinID: String? }
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
            guard case .object(let values)=try StrictJSON.parse(data) else { throw SkinError("配置格式无效") }
            let saved: PetSettings
            switch values["schemaVersion"] {
            case .number("1"):
                let legacy=try JSONDecoder().decode(LegacyConfiguration.self,from:data)
                saved=PetSettings(placement:legacy.placement)
            case .number("2"),.number("3"):
                let config=try JSONDecoder().decode(OldConfiguration.self,from:data)
                saved=PetSettings(placement:config.placement,preferences:.init(scale:config.preferences.scale,alwaysOnTop:config.preferences.alwaysOnTop),selectedSkinID:config.schemaVersion==3 ? config.selectedSkinID : nil)
            case .number("4"):
                let config=try JSONDecoder().decode(GazeConfiguration.self,from:data)
                saved=PetSettings(placement:config.placement,preferences:.init(scale:config.preferences.scale,alwaysOnTop:config.preferences.alwaysOnTop,lookAtMouse:config.preferences.lookAtMouse),selectedSkinID:config.selectedSkinID)
            case .number("5"):
                let config=try JSONDecoder().decode(ActionConfiguration.self,from:data),p=config.preferences
                saved=PetSettings(placement:config.placement,preferences:.init(scale:p.scale,alwaysOnTop:p.alwaysOnTop,lookAtMouse:p.lookAtMouse,automaticActions:p.automaticActions,automaticActionIntervalSeconds:p.automaticActionIntervalSeconds),selectedSkinID:config.selectedSkinID)
            case .number("6"):
                let config=try JSONDecoder().decode(Configuration.self,from:data)
                saved=PetSettings(placement:config.placement,preferences:config.preferences,selectedSkinID:config.selectedSkinID)
            default: throw SkinError("配置版本无效或尚不支持")
            }
            guard saved.isValid else { throw SkinError("配置中的位置或偏好无效") }
            blocked=false; return .loaded(saved)
        } catch { blocked=true; return .protectedFile(message:"配置无法读取，原文件已保留：\(error.localizedDescription)") }
    }
    public func save(_ settings: PetSettings) throws {
        if !checked { _=load() }
        guard !blocked else { throw SkinError("原配置受保护，请先备份并重置") }
        guard settings.isValid else { throw SkinError("位置或偏好无效，未保存") }
        let data=try JSONEncoder().encode(Configuration(schemaVersion:6,placement:settings.placement,preferences:settings.preferences,selectedSkinID:settings.selectedSkinID))
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
