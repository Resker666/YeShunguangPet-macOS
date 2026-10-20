import Foundation
import XCTest

enum SkinFixtures {
    static let minimalManifest = Data(#"{"schemaVersion": 1,"id":"my-pet","name":"我的角色","cellWidth":32,"cellHeight":32,"columns":2,"rows":1,"animations":{"idle":{"durationsMs":[300,200],"loop":true}}}"#.utf8)
    static func replacing(_ old: String, with new: String, in data: Data = minimalManifest) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
    }
    static func manifest(_ changes: [String: Any]) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: minimalManifest) as! [String: Any]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension SkinFixtures {
    static func directionalPNG() throws -> Data {
        var pixels=[UInt8](repeating:0,count:64*32*4)
        for y in 0..<32 { for x in 0..<64 where !(x==0 && y==0) {
            let p=(y*64+x)*4
            pixels[p+(y<16 ? 0 : 2)] = x<32 ? 255 : 128
            pixels[p+3]=255
        } }
        let provider=CGDataProvider(data:Data(pixels) as CFData)!
        let image=CGImage(width:64,height:32,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let data=NSMutableData()
        let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain:"fixture",code:1) }
        return data as Data
    }
    static func writePackage(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("pet.json")
        try minimalManifest.write(to:url)
        try directionalPNG().write(to:directory.appendingPathComponent("spritesheet.png"))
        return url
    }
}
