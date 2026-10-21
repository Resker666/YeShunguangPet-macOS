import XCTest
@testable import PetCore

final class KeyboardShortcutsTests:XCTestCase {
    func testDefaultAndModifierKeyContract() {
        XCTAssertEqual(PetPreferences().keyboardShortcuts,[])
        XCTAssertTrue(ShortcutCombination(keyCode:0,modifiers:[.control,.option]).isValid)
        for modifiers:ShortcutModifiers in [[.command,.shift],[.control],.init(rawValue:22),[]] {XCTAssertFalse(ShortcutCombination(keyCode:0,modifiers:modifiers).isValid)}
        for key:UInt32 in [24,36,49,UInt32.max] {XCTAssertFalse(ShortcutCombination(keyCode:key,modifiers:[.control,.option]).isValid)}
        XCTAssertEqual(KeyboardShortcuts.keys.count,48)
        for key in KeyboardShortcuts.keys {XCTAssertTrue(ShortcutCombination(keyCode:key.id,modifiers:[.control,.shift]).isValid)}
    }
    func testDuplicateActionsAndCombinationsRejected()throws {
        let a=ShortcutBinding(action:.recall,combination:.init(keyCode:0,modifiers:[.control,.option]))
        let b=ShortcutBinding(action:.toggleQuiet,combination:a.combination)
        XCTAssertThrowsError(try KeyboardShortcuts.validate([a,b]))
        XCTAssertThrowsError(try KeyboardShortcuts.validate([a,.init(action:.recall,combination:.init(keyCode:1,modifiers:[.control,.option]))]))
        let valid=ShortcutAction.allCases.enumerated().map{ShortcutBinding(action:$0.element,combination:.init(keyCode:UInt32($0.offset),modifiers:[.control,.option]))}
        XCTAssertNoThrow(try KeyboardShortcuts.validate(valid))
        XCTAssertEqual(try JSONDecoder().decode([ShortcutBinding].self,from:JSONEncoder().encode(valid)),valid)
    }
}
