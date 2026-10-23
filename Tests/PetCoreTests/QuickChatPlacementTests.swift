import XCTest
import CoreGraphics
import PetCore

final class QuickChatPlacementTests: XCTestCase {
    func testPlacementFitsRightLeftTopAndRemovedScreen() throws {
        let screen = ScreenArea(id: "main", visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800), isPrimary: true)
        let size = CGSize(width: 360, height: 300)
        XCTAssertEqual(QuickChatPlacement.frame(anchor: .init(x: 200, y: 200, width: 100, height: 100), size: size, screens: [screen]), .init(x: 308, y: 8, width: 360, height: 300))
        XCTAssertEqual(QuickChatPlacement.frame(anchor: .init(x: 800, y: 300, width: 100, height: 100), size: size, screens: [screen]), .init(x: 432, y: 100, width: 360, height: 300))
        let top = try XCTUnwrap(QuickChatPlacement.frame(anchor: .init(x: 300, y: 10, width: 400, height: 100), size: size, screens: [screen]))
        XCTAssertEqual(top.origin, .init(x: 320, y: 118))
        let left = ScreenArea(id: "left", visibleFrame: .init(x: -1000, y: -100, width: 1000, height: 800), isPrimary: false)
        let anchor = CGRect(x: -500, y: 200, width: 200, height: 200)
        let negative = try XCTUnwrap(QuickChatPlacement.frame(anchor: anchor, size: size, screens: [screen, left]))
        XCTAssertTrue(left.visibleFrame.insetBy(dx: 8, dy: 8).contains(negative))
        let removed = try XCTUnwrap(QuickChatPlacement.frame(anchor: anchor, size: size, screens: [screen]))
        XCTAssertTrue(screen.visibleFrame.insetBy(dx: 8, dy: 8).contains(removed))
        let huge = try XCTUnwrap(QuickChatPlacement.frame(anchor: .init(x: 900, y: 700, width: 800, height: 800), size: .init(width: 2000, height: 2000), screens: [screen]))
        XCTAssertEqual(huge, screen.visibleFrame.insetBy(dx: 8, dy: 8))
        XCTAssertNil(QuickChatPlacement.frame(anchor: anchor, size: size, screens: []))
        XCTAssertNil(QuickChatPlacement.frame(anchor: anchor, size: .zero, screens: [screen]))
        XCTAssertNil(QuickChatPlacement.frame(anchor: .null, size: size, screens: [screen]))
    }
}
