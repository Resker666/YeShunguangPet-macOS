import Foundation
import zlib

enum ZIPFixtures {
    struct Entry {
        var name:String,data:Data,method:UInt16=0,flags:UInt16=0x800,mode:UInt32=0o100644
        var declaredSize:Int?,extra=Data(),localExtra:Data?,compressedSuffix=Data(),descriptorSignature=true
        init(_ name:String,_ data:Data=Data(),method:UInt16=0,flags:UInt16=0x800,mode:UInt32=0o100644,declaredSize:Int?=nil) {
            self.name=name;self.data=data;self.method=method;self.flags=flags;self.mode=mode;self.declaredSize=declaredSize
        }
    }
    static func archive(_ entries:[Entry],comment:Data=Data()) throws -> Data {
        var result=Data(),central=Data()
        func fields(_ values:[(UInt32,Int)])->Data {
            var out=Data();for (value,size) in values {for shift in 0..<size {out.append(UInt8(truncatingIfNeeded:value >> (shift*8)))}};return out
        }
        for e in entries {
            let name=Data(e.name.utf8),body=(try e.method==8 ? deflated(e.data) : e.data)+e.compressedSuffix,localExtra=e.localExtra ?? e.extra
            let crc=e.data.withUnsafeBytes{UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt($0.count)))}
            let packed=UInt32(body.count),size=UInt32(e.declaredSize ?? e.data.count),offset=UInt32(result.count),dd=e.flags & 8 != 0
            result += fields([(0x04034b50,4),(20,2),(UInt32(e.flags),2),(UInt32(e.method),2),(0,4),(dd ? 0:crc,4),(dd ? 0:packed,4),(dd ? 0:size,4),(UInt32(name.count),2),(UInt32(localExtra.count),2)])
            result += name+localExtra+body
            if dd {if e.descriptorSignature{result += fields([(0x08074b50,4)])};result += fields([(crc,4),(packed,4),(size,4)])}
            central += fields([(0x02014b50,4),(0x0314,2),(20,2),(UInt32(e.flags),2),(UInt32(e.method),2),(0,4),(crc,4),(packed,4),(size,4),(UInt32(name.count),2),(UInt32(e.extra.count),2),(0,2),(0,2),(0,2),(e.mode << 16,4),(offset,4)])
            central += name+e.extra
        }
        let offset=result.count;result += central
        result += fields([(0x06054b50,4),(0,2),(0,2),(UInt32(entries.count),2),(UInt32(entries.count),2),(UInt32(central.count),4),(UInt32(offset),4),(UInt32(comment.count),2)])+comment
        return result
    }
    static func write(_ entries:[Entry],to url:URL) throws -> URL {try archive(entries).write(to:url);return url}
    static func unicodeExtra(name:String,path:String)->Data {
        let raw=Data(name.utf8),crc=raw.withUnsafeBytes{UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt($0.count)))},unicode=Data(path.utf8),length=unicode.count+5
        return Data([0x75,0x70,UInt8(truncatingIfNeeded:length),UInt8(truncatingIfNeeded:length >> 8),1]+(0..<4).map{UInt8(truncatingIfNeeded:crc >> ($0*8))})+unicode
    }
    private static func deflated(_ data:Data) throws -> Data {
        var stream=z_stream()
        guard deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw NSError(domain:"ZIPFixture",code:1)}
        defer{deflateEnd(&stream)}
        return try data.withUnsafeBytes {raw in
            stream.next_in=UnsafeMutablePointer(mutating:raw.bindMemory(to:Bytef.self).baseAddress);stream.avail_in=uInt(raw.count)
            var output=Data(),buffer=[UInt8](repeating:0,count:65536)
            while true {
                let status=buffer.withUnsafeMutableBytes {bytes in stream.next_out=bytes.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(bytes.count);return deflate(&stream,Z_FINISH)}
                output.append(contentsOf:buffer.prefix(65536-Int(stream.avail_out)))
                if status==Z_STREAM_END{return output}
                guard status==Z_OK else {throw NSError(domain:"ZIPFixture",code:Int(status))}
            }
        }
    }
}
