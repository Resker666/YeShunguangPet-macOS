import Foundation
import zlib

// Only verified JSON/PNG bytes reach the existing loader; archive paths are never extracted.
enum SkinArchive {
    static func readPackage(at url:URL) throws -> SkinPackage {
        let archive=try ZIPArchive(data:SkinLoader.readFile(at:url,maximumBytes:80*1024*1024))
        let manifests=archive.entries.filter{!$0.isDirectory && $0.path.components(separatedBy:"/").first?.lowercased() != "__macosx" && $0.path.components(separatedBy:"/").last?.lowercased()=="pet.json"}
        guard manifests.count==1 else {throw SkinError(manifests.isEmpty ? "ZIP 中未找到 pet.json。请选择只包含一套皮肤的 ZIP。":"ZIP 中包含多套皮肤，请先解压并选择其中一套。")}
        let entry=manifests[0],json=try archive.unpack(entry)
        let manifest=try ManifestDecoder.decode(json)
        let parent=entry.path.components(separatedBy:"/").dropLast().joined(separator:"/")
        let spritePath=(parent.isEmpty ? "":parent+"/")+manifest.spriteSheet
        guard let sprite=archive.entries.first(where:{!$0.isDirectory && ZIPArchive.key($0.path)==ZIPArchive.key(spritePath)}) else {throw SkinError("ZIP 中缺少与 pet.json 同目录的 PNG：\(manifest.spriteSheet)")}
        var png=Data()
        for item in archive.entries where item.path != entry.path {
            let bytes=try archive.unpack(item,retain:item.path==sprite.path)
            if item.path==sprite.path {png=bytes}
        }
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("ysg-zip-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            try json.write(to:temporary.appendingPathComponent("pet.json"),options:.withoutOverwriting)
            try png.write(to:temporary.appendingPathComponent(manifest.spriteSheet),options:.withoutOverwriting)
            let package=try SkinLoader.readPackage(manifestURL:temporary.appendingPathComponent("pet.json"))
            // SkinPackage owns the validated byte snapshot and CGImage, independent of source files.
            try FileManager.default.removeItem(at:temporary)
            return package
        } catch {
            if FileManager.default.fileExists(atPath:temporary.path) {
                do {try FileManager.default.removeItem(at:temporary)}
                catch let cleanup {throw SkinImportCleanupError(message:"ZIP 临时素材未能清理：\(cleanup.localizedDescription)")}
            }
            throw error
        }
    }
}

private struct ZIPArchive {
    struct Entry {
        let path:String,isDirectory:Bool,method:Int,crc:UInt32,size:Int,payload:Range<Int>
    }
    let data:Data,entries:[Entry]
    static func key(_ path:String)->String {path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))}
    init(data:Data) throws {
        let reader=ZIPBytes(data:data)
        guard data.count>=22,let end=(max(0,data.count-65557)...data.count-22).reversed().first(where:{
            (try? reader.number($0,4))==0x06054b50 && $0+22+((try? reader.number($0+20,2)) ?? -1)==data.count
        }) else {throw SkinError("ZIP 不完整或结束记录无效")}
        let count=try reader.number(end+10,2),centralSize=try reader.number(end+12,4),centralOffset=try reader.number(end+16,4)
        guard try reader.number(end+4,2)==0,try reader.number(end+6,2)==0,try reader.number(end+8,2)==count,
              (1...512).contains(count),centralOffset<=end,centralSize==end-centralOffset else {throw SkinError("ZIP 分卷、ZIP64、空包或文件数量超过限制；请先解压后选择皮肤")}
        var offset=centralOffset,entries=[Entry](),paths=[String:Bool](),ranges=[Range<Int>](),total=0
        for _ in 0..<count {
            try reader.require(offset,46)
            guard try reader.number(offset,4)==0x02014b50 else {throw SkinError("ZIP 目录记录无效")}
            let flags=try reader.number(offset+8,2),method=try reader.number(offset+10,2),crc=UInt32(try reader.number(offset+16,4))
            let packed=try reader.number(offset+20,4),size=try reader.number(offset+24,4),nameLength=try reader.number(offset+28,2),extraLength=try reader.number(offset+30,2),comment=try reader.number(offset+32,2)
            let attributes=try reader.number(offset+38,4),local=try reader.number(offset+42,4),mode=(attributes >> 16) & 0o170000
            guard flags & ~0x80e==0,[0,8].contains(method),try reader.number(offset+34,2)==0 else {throw SkinError("ZIP 加密、分卷或压缩方式不受支持；请先解压后选择皮肤")}
            guard nameLength>0,nameLength<=4096,size<=64*1024*1024,total<=128*1024*1024-size else {throw SkinError("ZIP 文件大小超过限制")}
            total += size
            try reader.require(offset+46,nameLength+extraLength+comment)
            guard offset+46+nameLength+extraLength+comment<=end else {throw SkinError("ZIP 目录越界")}
            let rawName=try reader.bytes(offset+46,nameLength),extra=try reader.bytes(offset+46+nameLength,extraLength)
            let path=try Self.path(rawName,extra:extra),isDirectory=path.hasSuffix("/")
            guard [0,0o100000,0o040000].contains(mode),mode != 0o040000 || isDirectory,mode != 0o100000 || !isDirectory,!isDirectory || size==0 else {throw SkinError("ZIP 中不允许符号链接或特殊文件")}
            let clean=isDirectory ? String(path.dropLast()):path,key=Self.key(clean)
            guard paths[key]==nil else {throw SkinError("ZIP 中存在重复文件路径")};paths[key]=isDirectory
            if clean.components(separatedBy:"/").last?.lowercased()=="pet.json",size>131072 {throw SkinError("ZIP 中的 pet.json 超过大小限制")}
            try reader.require(local,30)
            guard local<centralOffset,try reader.number(local,4)==0x04034b50,try reader.number(local+6,2)==flags,try reader.number(local+8,2)==method else {throw SkinError("ZIP 本地记录与目录不一致")}
            let localName=try reader.number(local+26,2),localExtra=try reader.number(local+28,2)
            guard try reader.bytes(local+30,localName)==rawName else {throw SkinError("ZIP 文件名记录不一致")}
            if let localUnicode=try Self.unicodeName(rawName,extra:reader.bytes(local+30+localName,localExtra)) {
                guard try Self.normalizedPath(localUnicode)==path else {throw SkinError("ZIP 本地与中央 Unicode 路径不一致")}
            }
            let start=local+30+localName+localExtra
            guard start<=centralOffset,packed<=centralOffset-start else {throw SkinError("ZIP 数据越界")}
            var recordEnd=start+packed
            if flags & 8 != 0 {
                // Signed and unsigned 32-bit data descriptors are both common.
                let signed=(try? reader.number(recordEnd,4))==0x08074b50
                let dd=recordEnd+(signed ? 4:0)
                guard dd<=centralOffset-12,try reader.number(dd,4)==Int(crc),try reader.number(dd+4,4)==packed,try reader.number(dd+8,4)==size else {throw SkinError("ZIP 数据描述记录不一致")}
                recordEnd=dd+12
            } else {
                guard try reader.number(local+14,4)==Int(crc),try reader.number(local+18,4)==packed,try reader.number(local+22,4)==size else {throw SkinError("ZIP 大小或校验记录不一致")}
            }
            ranges.append(local..<recordEnd)
            entries.append(.init(path:clean,isDirectory:isDirectory,method:method,crc:crc,size:size,payload:start..<start+packed))
            offset += 46+nameLength+extraLength+comment
        }
        guard offset==end else {throw SkinError("ZIP 目录大小不一致")}
        let sorted=ranges.sorted{$0.lowerBound<$1.lowerBound}
        for index in 1..<sorted.count where sorted[index].lowerBound<sorted[index-1].upperBound {throw SkinError("ZIP 文件数据重叠")}
        for path in paths.keys {
            var components=path.components(separatedBy:"/");components.removeLast()
            while !components.isEmpty {
                guard paths[components.joined(separator:"/")] != false else {throw SkinError("ZIP 文件和目录路径冲突")}
                components.removeLast()
            }
        }
        self.data=data;self.entries=entries
    }
    private static func unicodeName(_ name:Data,extra:Data) throws -> String? {
        let reader=ZIPBytes(data:extra);var offset=0,result:String?
        while offset<extra.count {
            let kind=try reader.number(offset,2),length=try reader.number(offset+2,2)
            try reader.require(offset+4,length)
            guard kind != 1 else {throw SkinError("暂不支持 ZIP64，请先解压后选择皮肤")}
            if kind==0x7075 {
                guard length>=5,try reader.number(offset+4,1)==1,try reader.number(offset+5,4)==Int(checksum(name)),let text=String(data:try reader.bytes(offset+9,length-5),encoding:.utf8),result==nil else {throw SkinError("ZIP Unicode 文件名记录无效")}
                result=text
            }
            offset += 4+length
        }
        return result
    }
    private static func path(_ raw:Data,extra:Data) throws -> String {
        guard let path=try unicodeName(raw,extra:extra) ?? String(data:raw,encoding:.utf8) else {throw SkinError("ZIP 文件名编码不受支持，请先解压后选择皮肤")}
        return try normalizedPath(path)
    }
    private static func normalizedPath(_ original:String) throws -> String {
        guard !original.isEmpty else {throw SkinError("ZIP 文件路径为空")}
        var path=original
        while path.hasPrefix("./"){path.removeFirst(2)}
        // bsdtar and other ordinary writers include an explicit root directory.
        // Keep its identity; the caller still checks directory type, size and CRC.
        if path.isEmpty || path=="." {return "./"}
        let clean=path.hasSuffix("/") ? String(path.dropLast()):path,parts=clean.components(separatedBy:"/")
        guard !clean.isEmpty,clean.utf8.count<=1024,parts.count<=16,!path.contains(where:{"\\:".contains($0)}),!path.unicodeScalars.contains(where:{$0.properties.generalCategory == .control}),parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else {throw SkinError("ZIP 中含不安全或过深的文件路径")}
        return path
    }
    private static func checksum(_ data:Data)->UInt32 {data.withUnsafeBytes{UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt($0.count)))}}
    func unpack(_ entry:Entry,retain:Bool=true) throws -> Data {
        let compressed=data.subdata(in:entry.payload)
        if entry.method==0 {
            guard compressed.count==entry.size,Self.checksum(compressed)==entry.crc else {throw SkinError("ZIP 文件大小或 CRC 校验失败")}
            return retain ? compressed:Data()
        }
        var stream=z_stream()
        guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw SkinError("ZIP 解压初始化失败")}
        defer{inflateEnd(&stream)}
        return try compressed.withUnsafeBytes {raw in
            stream.next_in=UnsafeMutablePointer(mutating:raw.bindMemory(to:Bytef.self).baseAddress);stream.avail_in=uInt(raw.count)
            var output=Data(),buffer=[UInt8](repeating:0,count:65536),count=0,crc:UInt32=0
            while true {
                let previous=stream.avail_in
                let status=buffer.withUnsafeMutableBytes {bytes in stream.next_out=bytes.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(bytes.count);return zlib.inflate(&stream,Z_NO_FLUSH)}
                let produced=65536-Int(stream.avail_out)
                guard produced<=entry.size-count else {throw SkinError("ZIP 实际解压大小超过限制")}
                count += produced
                crc=buffer.withUnsafeBytes{UInt32(crc32(uLong(crc),$0.bindMemory(to:Bytef.self).baseAddress,uInt(produced)))}
                if retain {output.append(contentsOf:buffer.prefix(produced))}
                if status==Z_STREAM_END {
                    guard count==entry.size,stream.avail_in==0,crc==entry.crc else {throw SkinError("ZIP 文件大小或 CRC 校验失败")}
                    return output
                }
                guard status==Z_OK,produced>0 || stream.avail_in<previous else {throw SkinError("ZIP 压缩数据损坏或不完整")}
            }
        }
    }
}

private struct ZIPBytes {
    let data:Data
    func require(_ offset:Int,_ length:Int) throws {
        guard offset>=0,length>=0,length<=data.count,offset<=data.count-length else {throw SkinError("ZIP 记录被截断或越界")}
    }
    func bytes(_ offset:Int,_ length:Int) throws -> Data {try require(offset,length);return data.subdata(in:offset..<offset+length)}
    func number(_ offset:Int,_ length:Int) throws -> Int {try require(offset,length);return (0..<length).reduce(0){$0 | Int(data[offset+$1]) << ($1*8)}}
}
