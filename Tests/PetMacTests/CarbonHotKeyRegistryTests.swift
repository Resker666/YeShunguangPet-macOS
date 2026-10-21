import AppKit
import XCTest
import PetCore

@MainActor final class CarbonHotKeyRegistryTests:XCTestCase {
    func testExclusiveRegistrationConflictAndRelease()throws {
        _=NSApplication.shared
        let first=CarbonHotKeyRegistry(),second=CarbonHotKeyRegistry()
        defer{try? first.dispose();try? second.dispose()}
        let combination=ShortcutCombination(keyCode:111,modifiers:[.control,.option,.shift,.command])
        try first.register(combination,id:1)
        XCTAssertThrowsError(try second.register(combination,id:2))
        try first.unregister(id:1)
        try second.register(combination,id:3)
        try second.unregister(id:3)
        try first.dispose();try second.dispose()
        XCTAssertThrowsError(try first.register(combination,id:4))
    }
}
