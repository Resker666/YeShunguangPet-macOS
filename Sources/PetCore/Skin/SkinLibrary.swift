import Foundation
import Darwin

public struct ImportedSkin: Sendable {
    public let id: String
    public let skin: LoadedSkin
}

public struct SkinLibrary: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory=directory }
    static func isValidID(_ id: String) -> Bool { UUID(uuidString:id) != nil }
    private func checkRoot(create: Bool = false) throws {
        if create { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
        var info=stat()
        guard lstat(directory.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR else { throw SkinError("导入素材目录不可用或是符号链接") }
    }
    public func install(_ package: SkinPackage, writeFile: (Data,URL) throws -> Void = { try $0.write(to:$1,options:.withoutOverwriting) }) throws -> ImportedSkin {
        try checkRoot(create:true)
        let id=UUID().uuidString
        let staging=directory.appendingPathComponent(".import-\(id)",isDirectory:true)
        let destination=directory.appendingPathComponent(id,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        var published=false
        do {
            try writeFile(package.manifestData,staging.appendingPathComponent("pet.json"))
            try writeFile(package.spriteSheetData,staging.appendingPathComponent(package.skin.manifest.spriteSheet))
            _=try SkinLoader.load(manifestURL:staging.appendingPathComponent("pet.json"))
            try FileManager.default.moveItem(at:staging,to:destination); published=true
            return ImportedSkin(id:id,skin:try load(id:id))
        } catch {
            do { try FileManager.default.removeItem(at:published ? destination : staging) }
            catch let cleanup { throw SkinError("导入失败且临时素材未能清理：\(error.localizedDescription)；\(cleanup.localizedDescription)") }
            throw error
        }
    }
    public func load(id: String) throws -> LoadedSkin {
        guard Self.isValidID(id) else { throw SkinError("导入皮肤标识无效") }
        try checkRoot()
        return try SkinLoader.load(manifestURL:directory.appendingPathComponent(id,isDirectory:true).appendingPathComponent("pet.json"))
    }
    public func discardNewImport(id: String) throws {
        guard Self.isValidID(id) else { throw SkinError("导入皮肤标识无效") }
        try checkRoot()
        try FileManager.default.removeItem(at:directory.appendingPathComponent(id,isDirectory:true))
    }
}
