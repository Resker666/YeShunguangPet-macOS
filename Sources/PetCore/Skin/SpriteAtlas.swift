import Foundation
import CoreGraphics

public final class SpriteAtlas {
    private let skin: LoadedSkin
    private var cache: [FrameLocation:CGImage]=[:]
    public init(skin: LoadedSkin) { self.skin=skin }
    public func frame(at location: FrameLocation) throws -> CGImage {
        let m=skin.manifest
        guard (0..<m.rows).contains(location.row),(0..<m.columns).contains(location.column) else { throw SkinError("帧坐标超出皮肤范围") }
        if let frame=cache[location] { return frame }
        guard let frame=skin.spriteSheet.cropping(to:CGRect(x:location.column*m.cellWidth,y:location.row*m.cellHeight,width:m.cellWidth,height:m.cellHeight)) else { throw SkinError("帧裁剪失败") }
        cache[location]=frame; return frame
    }
}
