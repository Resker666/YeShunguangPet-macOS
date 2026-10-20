import AppKit
import XCTest
import PetCore

@MainActor final class PetPanelTests: XCTestCase {
    func testNonactivatingTransparentAndCorrectDrawDirection() throws {
        _=NSApplication.shared
        let panel=PetPanel(size:CGSize(width:32,height:32)); defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain); XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.contentRect(forFrameRect:panel.frame).size,CGSize(width:32,height:32))
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let skin=try SkinLoader.load(manifestURL:SkinFixtures.writePackage(in:directory))
        let view=PetView(frame:CGRect(x:0,y:0,width:32,height:32)); panel.contentView=view
        view.image=try SpriteAtlas(skin:skin).frame(at:.init(row:0,column:0))
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let top=try XCTUnwrap(bitmap.colorAt(x:1,y:1)?.usingColorSpace(.deviceRGB))
        let bottom=try XCTUnwrap(bitmap.colorAt(x:1,y:30)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent,0.9); XCTAssertGreaterThan(bottom.blueComponent,0.9)
        XCTAssertEqual(bitmap.colorAt(x:0,y:0)?.alphaComponent,0)
        // Resize the existing frame without receiving a new animation image.
        panel.setContentSize(CGSize(width:64,height:64)); view.setFrameSize(CGSize(width:64,height:64))
        let resized=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:resized)
        XCTAssertGreaterThan(try XCTUnwrap(resized.colorAt(x:4,y:4)?.usingColorSpace(.deviceRGB)).redComponent,0.9)
        XCTAssertGreaterThan(try XCTUnwrap(resized.colorAt(x:4,y:60)?.usingColorSpace(.deviceRGB)).blueComponent,0.9)
    }
}
