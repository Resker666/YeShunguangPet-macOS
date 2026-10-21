import AppKit
import ServiceManagement
import XCTest

@MainActor private final class LoginItemInput {var status=SMAppService.Status.notRegistered}
@MainActor final class LoginItemTests:XCTestCase {
    func testSuccessfulRegistrationAndRemovalReflectSystemState() {
        for initial in [SMAppService.Status.notRegistered,.notFound] {
        let input=LoginItemInput()
        input.status=initial
        let model=LoginItemController(bundleURL:URL(fileURLWithPath:"/Applications/YeShunguangPet.app"),status:{input.status},register:{input.status = .enabled},unregister:{input.status = .notRegistered})
        XCTAssertFalse(model.isSelected)
        model.setEnabled(true);XCTAssertTrue(model.isSelected);XCTAssertEqual(model.status,.enabled);XCTAssertNil(model.lastError)
        model.setEnabled(false);XCTAssertFalse(model.isSelected);XCTAssertEqual(model.status,.notRegistered)
        }
    }
    func testTemporaryAndMisleadingApplicationPathsCannotBeRegistered() {
        for path in ["/private/tmp/YeShunguangPet.app","/Applications-Old/YeShunguangPet.app","/Volumes/安装盘/YeShunguangPet.app"] {
            let input=LoginItemInput()
            let model=LoginItemController(bundleURL:URL(fileURLWithPath:path),status:{input.status},register:{input.status = .enabled},unregister:{input.status = .notRegistered})
            model.setEnabled(true)
            XCTAssertFalse(model.canEnable);XCTAssertFalse(model.isSelected);XCTAssertNotNil(model.lastError)
        }
    }
    func testPendingApprovalIsNotReportedAsEnabledAndMayBeCancelled() {
        let input=LoginItemInput()
        let model=LoginItemController(bundleURL:URL(fileURLWithPath:"/Applications/YeShunguangPet.app"),status:{input.status},register:{input.status = .requiresApproval},unregister:{input.status = .notRegistered})
        model.setEnabled(true);XCTAssertTrue(model.isSelected);XCTAssertEqual(model.status,.requiresApproval)
        XCTAssertNil(model.lastError)
        model.setEnabled(false);XCTAssertFalse(model.isSelected)
    }
    func testRegistrationFailureKeepsSwitchOffAndExplainsFailure() {
        let model=LoginItemController(bundleURL:URL(fileURLWithPath:"/Applications/YeShunguangPet.app"),status:{.notRegistered},register:{throw NSError(domain:"test.registration",code:1)},unregister:{})
        model.setEnabled(true);XCTAssertFalse(model.isSelected);XCTAssertNotNil(model.lastError)
    }
    func testRemovalFailureKeepsSwitchOnAndAllowsRetryFromTemporaryLocation() {
        let input=LoginItemInput();input.status = .enabled
        var fail=true
        let model=LoginItemController(bundleURL:URL(fileURLWithPath:"/private/tmp/YeShunguangPet.app"),status:{input.status},register:{},unregister:{if fail{throw NSError(domain:"test.removal",code:2)};input.status = .notRegistered})
        model.setEnabled(false);XCTAssertTrue(model.isSelected);XCTAssertNotNil(model.lastError)
        fail=false;model.setEnabled(false);XCTAssertFalse(model.isSelected);XCTAssertNil(model.lastError)
    }
    func testRefreshHonorsExternalSystemChangesWithoutRegisteringAgain() {
        let input=LoginItemInput();input.status = .enabled
        let model=LoginItemController(bundleURL:URL(fileURLWithPath:"/Applications/YeShunguangPet.app"),status:{input.status},register:{throw NSError(domain:"unexpected.register",code:3)},unregister:{})
        model.setEnabled(true);XCTAssertTrue(model.isSelected);XCTAssertNil(model.lastError)
        input.status = .requiresApproval;model.refresh();XCTAssertEqual(model.status,.requiresApproval)
        input.status = .notRegistered;model.refresh();XCTAssertFalse(model.isSelected)
    }
}
