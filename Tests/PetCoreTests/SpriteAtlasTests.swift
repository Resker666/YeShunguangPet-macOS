import Foundation
import XCTest
import CoreGraphics
@testable import PetCore
final class SpriteAtlasTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func testFrameDirectionTransparencyAndColumns() throws {
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let atlas=SpriteAtlas(skin:skin)
        func pixel(_ image: CGImage,_ x: Int,_ y: Int) -> [UInt8] {
            // Image provider order is top down; normalize through an RGBA CGContext.
            var data=[UInt8](repeating:0,count:image.width*image.height*4)
            data.withUnsafeMutableBytes { bytes in
                let ctx=CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }
            return Array(data[(y*image.width+x)*4..<(y*image.width+x)*4+4])
        }
        let left=try atlas.frame(at:.init(row:0,column:0)), right=try atlas.frame(at:.init(row:0,column:1))
        XCTAssertEqual(pixel(left,1,1),[255,0,0,255]); XCTAssertEqual(pixel(left,1,30),[0,0,255,255]); XCTAssertEqual(pixel(left,0,0),[0,0,0,0]); XCTAssertEqual(pixel(right,1,1),[128,0,0,255])
        XCTAssertThrowsError(try atlas.frame(at:.init(row:1,column:0)))
    }
}
