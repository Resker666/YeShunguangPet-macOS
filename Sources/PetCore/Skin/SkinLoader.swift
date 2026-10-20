import Foundation
import CoreGraphics
import ImageIO
import Darwin
import zlib

public struct LoadedSkin: Sendable {
    public let manifest: PetManifest
    public let spriteSheet: CGImage
    public let directory: URL
}
public struct SkinPackage: Sendable {
    public let skin: LoadedSkin
    let manifestData: Data, spriteSheetData: Data
}

public enum SkinLoader {
    private static func directoryHandle(_ url: URL) throws -> Int32 {
        let fd=open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else { throw SkinError("皮肤目录无法读取或是符号链接：\(url.path)") }
        return fd
    }
    private static func read(name: String, directoryFD: Int32, maximumBytes: Int) throws -> Data {
        let fd=openat(directoryFD,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else { throw SkinError("资源无法打开或是符号链接：\(name)") }; defer { close(fd) }
        var info=stat()
        guard fstat(fd,&info)==0, info.st_mode & S_IFMT == S_IFREG, info.st_size>0, info.st_size<=maximumBytes else { throw SkinError("资源不是普通文件、为空或超过限制：\(name)") }
        return try readLimited(maximumBytes:maximumBytes) { count in
            var buffer=[UInt8](repeating:0,count:count)
            var result: Int
            repeat { result=Darwin.read(fd,&buffer,count) } while result<0 && errno==EINTR
            guard result>=0 else { throw SkinError("资源读取失败：\(name)") }
            return Data(buffer.prefix(result))
        }
    }
    static func readLimited(maximumBytes: Int, next: (Int) throws -> Data) throws -> Data {
        guard maximumBytes>0 else { throw SkinError("读取上限无效") }
        var data=Data()
        while true {
            let chunk=try next(min(65536,maximumBytes-data.count+1))
            if chunk.isEmpty { break }
            guard chunk.count<=maximumBytes-data.count else { throw SkinError("资源读取过程中超过大小限制") }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw SkinError("资源为空") }; return data
    }
    public static func readFile(at url: URL, maximumBytes: Int) throws -> Data {
        let fd=try directoryHandle(url.deletingLastPathComponent()); defer { close(fd) }
        return try read(name:url.lastPathComponent,directoryFD:fd,maximumBytes:maximumBytes)
    }
    private static func validatePNGChunks(_ data: Data) throws {
        // ImageIO may return a partial image, even with a "complete" status.
        // Check the bounded byte stream before asking it to decode pixels.
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func integer(_ offset: Int) -> UInt32 {
                bytes[offset..<offset+4].reduce(UInt32(0)) { ($0<<8)|UInt32($1) }
            }
            var offset=8, sawImageData=false
            while offset<data.count {
                guard data.count-offset>=12 else { throw SkinError("PNG 数据块不完整") }
                let length=Int(integer(offset)), type=integer(offset+4)
                guard length<=data.count-offset-12 else { throw SkinError("PNG 数据块被截断") }
                let end=offset+12+length
                let pointer=bytes.bindMemory(to:Bytef.self).baseAddress!.advanced(by:offset+4)
                let checksum=UInt32(crc32(0,pointer,uInt(length+4)))
                guard checksum==integer(end-4) else { throw SkinError("PNG 数据块校验失败") }
                if type==0x49484452 && offset != 8 { throw SkinError("PNG 图像头重复") } // IHDR
                if type==0x49444154 { sawImageData=true } // IDAT
                if type==0x49454E44 { // IEND
                    guard length==0, sawImageData, end==data.count else { throw SkinError("PNG 结束块无效") }
                    return
                }
                offset=end
            }
            throw SkinError("PNG 缺少结束块")
        }
    }
    public static func load(manifestURL: URL) throws -> LoadedSkin {
        try readPackage(manifestURL:manifestURL).skin
    }
    public static func readPackage(manifestURL: URL) throws -> SkinPackage {
        guard manifestURL.isFileURL, manifestURL.lastPathComponent.lowercased()=="pet.json" else { throw SkinError("请选择本地皮肤目录中的 pet.json") }
        let directory=manifestURL.deletingLastPathComponent()
        let fd=try directoryHandle(directory); defer { close(fd) }
        let json=try read(name:manifestURL.lastPathComponent,directoryFD:fd,maximumBytes:131072)
        let manifest=try ManifestDecoder.decode(json)
        let png=try read(name:manifest.spriteSheet,directoryFD:fd,maximumBytes:64*1024*1024)
        let bytes=Array(png.prefix(33))
        guard bytes.count>=33, Array(bytes[0..<8])==[137,80,78,71,13,10,26,10], Array(bytes[8..<16])==[0,0,0,13,73,72,68,82] else { throw SkinError("精灵图不是有效 PNG") }
        func integer(_ offset: Int) -> Int { bytes[offset..<offset+4].reduce(0) { ($0<<8)|Int($1) } }
        let w=manifest.cellWidth*manifest.columns, h=manifest.cellHeight*manifest.rows
        guard integer(16)==w,integer(20)==h else { throw SkinError("PNG 实际尺寸与皮肤清单不一致") }
        try validatePNGChunks(png)
        guard let source=CGImageSourceCreateWithData(png as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary), image.width==w,image.height==h else { throw SkinError("PNG 无法完整解码") }
        return SkinPackage(skin:LoadedSkin(manifest:manifest,spriteSheet:image,directory:directory.resolvingSymlinksInPath()),manifestData:json,spriteSheetData:png)
    }
}
