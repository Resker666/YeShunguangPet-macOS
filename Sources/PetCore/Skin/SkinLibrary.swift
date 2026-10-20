import Foundation
import Darwin
import CoreGraphics

public struct SkinLibraryEntry: Sendable, Identifiable {
    public let id: String, name: String
    public let thumbnail: CGImage?
    public let loadError: String?
}
public struct SkinImportCleanupError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct ImportedSkin: Sendable {
    public let id: String
    public let skin: LoadedSkin
    public init(id: String, skin: LoadedSkin) { self.id=id; self.skin=skin }
}

public struct SkinLibrary: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory=directory }
    public func entries() throws -> [SkinLibraryEntry] {
        var root=stat()
        if lstat(directory.path,&root) != 0,errno==ENOENT { return [] }
        try checkRoot()
        let children=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        var result=[SkinLibraryEntry]()
        for child in children where Self.isValidID(child.lastPathComponent) {
            var info=stat()
            guard lstat(child.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR else { continue }
            let id=child.lastPathComponent
            do {
                let skin=try load(id:id), idle=skin.manifest.animations[.idle]!
                let frame=try SpriteAtlas(skin:skin).frame(at:.init(row:idle.row,column:idle.startColumn))
                let ratio=min(1,80/Double(frame.width),80/Double(frame.height))
                let width=max(1,Int((Double(frame.width)*ratio).rounded())),height=max(1,Int((Double(frame.height)*ratio).rounded()))
                // Copy into a small bitmap; a cropped CGImage can retain the full sprite sheet.
                guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SkinError("皮肤缩略图无法生成") }
                context.interpolationQuality = .high
                context.draw(frame,in:CGRect(x:0,y:0,width:width,height:height))
                guard let thumbnail=context.makeImage() else { throw SkinError("皮肤缩略图无法生成") }
                result.append(.init(id:id,name:skin.manifest.name,thumbnail:thumbnail,loadError:nil))
            } catch {
                result.append(.init(id:id,name:"无法读取的皮肤（\(id.prefix(8))）",thumbnail:nil,loadError:error.localizedDescription))
            }
        }
        return result.sorted { $0.name==$1.name ? $0.id<$1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func remove(id: String) throws {
        guard Self.isValidID(id) else { throw SkinError("导入皮肤标识无效") }
        try checkRoot()
        let target=directory.appendingPathComponent(id,isDirectory:true)
        var info=stat()
        guard lstat(target.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR else { throw SkinError("皮肤副本不存在或是符号链接，未删除") }
        try FileManager.default.removeItem(at:target)
    }
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
            catch let cleanup { throw SkinImportCleanupError(message:"导入失败且临时素材未能清理：\(error.localizedDescription)；\(cleanup.localizedDescription)") }
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
