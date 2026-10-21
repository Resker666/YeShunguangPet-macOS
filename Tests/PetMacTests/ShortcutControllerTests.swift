import AppKit
import XCTest
import PetCore

@MainActor final class ShortcutControllerTests:XCTestCase {
    private let a=ShortcutFixture.a,b=ShortcutFixture.b
    private func binding(_ action:ShortcutAction,_ combo:ShortcutCombination)->ShortcutBinding {.init(action:action,combination:combo)}
    func testReplaceConflictLeavesOldRegistrationAndFile()throws {
        let f=try ShortcutFixture(bindings:[binding(.recall,a)]);defer{f.close()}
        let original=try Data(contentsOf:f.settingsURL),entries=f.registry.registered
        f.registry.blocked=[b];f.controller.apply(b,to:.recall)
        XCTAssertEqual(f.registry.registered,entries);XCTAssertEqual(try Data(contentsOf:f.settingsURL),original)
        XCTAssertEqual(f.controller.statuses[.recall]?.active,a);XCTAssertNotNil(f.controller.statuses[.recall]?.message)
        f.controller.apply(a,to:.toggleQuiet);XCTAssertEqual(f.registry.registered,entries)
        f.controller.apply(.init(keyCode:0,modifiers:[.command]),to:.recall);XCTAssertEqual(f.registry.registered,entries)
    }
    func testSaveFailureRestoresOldOrReportsInactive()throws {
        for restoreFails in [false,true] {
            let f=try ShortcutFixture(bindings:[binding(.recall,a)]);defer{f.close()}
            let original=try Data(contentsOf:f.settingsURL)
            f.input.writeFails=true;if restoreFails{f.registry.blocked=[a]}
            f.controller.apply(b,to:.recall)
            XCTAssertEqual(f.session.preferences.keyboardShortcuts,[binding(.recall,a)])
            XCTAssertEqual(try Data(contentsOf:f.settingsURL),original)
            XCTAssertEqual(f.controller.statuses[.recall]?.active,restoreFails ? nil : a)
            XCTAssertNotNil(f.controller.statuses[.recall]?.message)
            XCTAssertFalse(f.registry.registered.values.contains(b))
        }
    }
    func testUnregisterFailureRetainsActualOccupancyAndCanRetry()throws {
        let f=try ShortcutFixture(bindings:[binding(.toggleQuiet,a)]);defer{f.close()}
        f.input.writeFails=true;f.registry.failedRemovals=[2]
        f.controller.apply(b,to:.toggleQuiet)
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.active,a)
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.pendingCleanup,[b])
        f.registry.emit(2);XCTAssertFalse(f.session.isQuiet)
        f.input.writeFails=false;f.registry.failedRemovals=[];f.controller.retry(.toggleQuiet)
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.pendingCleanup,[])
        XCTAssertFalse(f.registry.registered.values.contains(b))
        let old=try XCTUnwrap(f.registry.registered.first{$0.value==a}?.key)
        f.registry.failedRemovals=[old]
        let original=try Data(contentsOf:f.settingsURL)
        f.controller.apply(b,to:.toggleQuiet)
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.active,a)
        XCTAssertEqual(try Data(contentsOf:f.settingsURL),original)
    }
    func testStartupConflictClearProtectedResetAndDispose()throws {
        let f=try ShortcutFixture(bindings:[binding(.recall,a),binding(.toggleQuiet,b)],blocked:[a]);defer{f.close()}
        XCTAssertNil(f.controller.statuses[.recall]?.active);XCTAssertEqual(f.controller.statuses[.recall]?.remembered,a)
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.active,b)
        let calls=f.registry.registerCalls;f.controller.start();XCTAssertEqual(f.registry.registerCalls,calls)
        f.registry.blocked=[];f.controller.retry(.recall);XCTAssertEqual(f.controller.statuses[.recall]?.active,a)
        f.input.writeFails=true;f.controller.apply(nil,to:.recall);XCTAssertEqual(f.controller.statuses[.recall]?.active,a)
        f.input.writeFails=false;f.controller.apply(nil,to:.recall);XCTAssertNil(f.controller.statuses[.recall]?.remembered)
        let callback=f.registry.onEvent;f.controller.dispose();callback?(2,true);XCTAssertFalse(f.session.isQuiet);XCTAssertTrue(f.registry.registered.isEmpty)
        let protected=try ShortcutFixture(corrupt:true);defer{protected.close()}
        let bad=try Data(contentsOf:protected.settingsURL)
        protected.controller.apply(a,to:.recall);XCTAssertTrue(protected.registry.registered.isEmpty);XCTAssertEqual(try Data(contentsOf:protected.settingsURL),bad)
        protected.session.resetProtectedSettings();protected.controller.apply(a,to:.recall)
        XCTAssertEqual(protected.controller.statuses[.recall]?.active,a)
    }
    func testHeldSuppressedAndStaleEventsDoNotToggle()throws {
        let f=try ShortcutFixture(bindings:[binding(.toggleQuiet,a)]);defer{f.close()}
        let id=try XCTUnwrap(f.registry.registered.first?.key)
        f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertFalse(f.session.isQuiet)
        f.registry.emit(id,down:false);f.input.allowsDispatch=false;f.registry.emit(id)
        f.input.allowsDispatch=true;f.registry.emit(id);XCTAssertFalse(f.session.isQuiet)
        f.registry.emit(id,down:false);f.registry.emit(id);XCTAssertTrue(f.session.isQuiet)
        f.controller.apply(b,to:.toggleQuiet);f.registry.emit(id,down:false);f.registry.emit(id);f.registry.emit(999)
        XCTAssertTrue(f.session.isQuiet)
    }
    func testCommandsUseSessionAndNormalSettingsAllowDispatch()throws {
        let f=try ShortcutFixture();defer{f.close()}
        f.controller.apply(a,to:.toggleVisibility);f.controller.apply(b,to:.recall)
        let hide=try XCTUnwrap(f.registry.registered.first{$0.value==a}?.key),recall=try XCTUnwrap(f.registry.registered.first{$0.value==b}?.key)
        f.session.setSettingsOpen(true);f.registry.emit(hide);XCTAssertFalse(f.session.isVisible)
        f.registry.emit(recall);XCTAssertTrue(f.session.isVisible)
        f.input.allowsDispatch=false;f.registry.emit(hide,down:false);f.registry.emit(hide);XCTAssertTrue(f.session.isVisible)
        f.session.prepareToExit();f.input.allowsDispatch=true;f.registry.emit(hide,down:false);f.registry.emit(hide);XCTAssertTrue(f.session.gate.exiting)
    }
    func testPartialDisposalReportsOnlyUnreleasedBindingsAndCanRetry()throws {
        let f=try ShortcutFixture(bindings:[binding(.recall,a),binding(.toggleQuiet,b)]);defer{f.close()}
        let failed=try XCTUnwrap(f.registry.registered.first{$0.value==b}?.key)
        f.registry.failedRemovals=[failed];f.controller.dispose()
        XCTAssertNil(f.controller.statuses[.recall]?.active)
        XCTAssertEqual(f.controller.statuses[.recall]?.pendingCleanup,[])
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.pendingCleanup,[b])
        f.registry.emit(failed);XCTAssertFalse(f.session.isQuiet)
        f.registry.failedRemovals=[];f.controller.dispose()
        XCTAssertTrue(f.registry.registered.isEmpty)
        XCTAssertEqual(f.controller.statuses[.toggleQuiet]?.pendingCleanup,[])
    }
    func testSessionShortcutSaveCommitsOnlyOnSuccessAndCannotBeBypassed()throws {
        let f=try ShortcutFixture();defer{f.close()}
        let original=try Data(contentsOf:f.settingsURL)
        var prefs=f.session.preferences;prefs.keyboardShortcuts=[binding(.recall,a)]
        f.session.setPreferences(prefs);XCTAssertTrue(f.session.preferences.keyboardShortcuts.isEmpty)
        f.input.writeFails=true;XCTAssertThrowsError(try f.session.saveKeyboardShortcuts(prefs.keyboardShortcuts))
        XCTAssertTrue(f.session.preferences.keyboardShortcuts.isEmpty);XCTAssertEqual(try Data(contentsOf:f.settingsURL),original)
        f.input.writeFails=false;try f.session.saveKeyboardShortcuts(prefs.keyboardShortcuts)
        XCTAssertEqual(f.session.preferences.keyboardShortcuts,prefs.keyboardShortcuts)
    }
}
