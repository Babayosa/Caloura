import AppKit
import XCTest
@testable import Caloura

@MainActor
final class ScreenCaptureManagerPermissionAlertTests: XCTestCase {
    // MARK: - showPermissionAlert

    func testShowPermissionAlert_neverGrantedOpensSettings() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .openSystemSettings
            )
        )

        _ = await manager.showPermissionAlert(for: .neverGranted)

        XCTAssertEqual(box.openedURLs.count, 1)
        XCTAssertTrue(box.openedURLs[0].absoluteString.contains("Privacy_ScreenCapture"))
    }

    func testShowPermissionAlert_neverGrantedCancelDoesNothing() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .cancel
            )
        )

        _ = await manager.showPermissionAlert(for: .neverGranted)

        XCTAssertTrue(box.openedURLs.isEmpty)
        XCTAssertEqual(box.terminateCount, 0)
    }

    func testShowPermissionAlert_neverGrantedRestartDoesNothing() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .restartApp
            )
        )

        _ = await manager.showPermissionAlert(for: .neverGranted)

        XCTAssertTrue(box.openedURLs.isEmpty)
        XCTAssertEqual(box.terminateCount, 0)
    }

    func testShowPermissionAlert_grantedButFailingRestartRelaunchesAndTerminates() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .restartApp
            )
        )
        let expectation = expectation(description: "terminate called")
        box.onTerminate = {
            expectation.fulfill()
        }

        _ = await manager.showPermissionAlert(for: .grantedButFailing)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(box.runRepairToolCalls.isEmpty)
    }

    func testShowPermissionAlert_grantedButFailingOpenSettingsUsesURLHandler() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .openSystemSettings
            )
        )

        _ = await manager.showPermissionAlert(for: .grantedButFailing)

        XCTAssertEqual(box.openedURLs.count, 1)
    }

    func testShowPermissionAlert_grantedButFailingCancelDoesNothing() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .cancel
            )
        )

        _ = await manager.showPermissionAlert(for: .grantedButFailing)

        XCTAssertTrue(box.openedURLs.isEmpty)
        XCTAssertEqual(box.terminateCount, 0)
    }

    func testShowPermissionAlert_confirmRepairRelaunchReturnsActionWithoutSideEffects() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .restartApp
            )
        )

        let action = await manager.showPermissionAlert(for: .confirmRepairRelaunch)

        XCTAssertEqual(action, .restartApp)
        XCTAssertTrue(box.openedURLs.isEmpty)
        XCTAssertTrue(box.runRepairToolCalls.isEmpty)
        XCTAssertEqual(box.terminateCount, 0)
    }

    func testShowPermissionAlert_confirmRepairRelaunchCancelDoesNothing() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                alertAction: .cancel
            )
        )

        let action = await manager.showPermissionAlert(for: .confirmRepairRelaunch)

        XCTAssertEqual(action, .cancel)
        XCTAssertTrue(box.openedURLs.isEmpty)
        XCTAssertEqual(box.terminateCount, 0)
    }

    // MARK: - makePermissionAlert

    func testMakePermissionAlert_neverGrantedHasSettingsAndCancelButtons() {
        let alert = ScreenCaptureManager.makePermissionAlert(for: .neverGranted)

        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.messageText, "Screen Recording Permission Required")
        XCTAssertTrue(alert.informativeText.contains("Open System Settings"))
        XCTAssertEqual(
            alert.buttons.map(\.title),
            ["Open System Settings", "Cancel"]
        )
    }

    func testMakePermissionAlert_grantedButFailingHasRestartSettingsAndCancelButtons() {
        let alert = ScreenCaptureManager.makePermissionAlert(for: .grantedButFailing)

        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.messageText, "Screen Recording Permission Issue")
        XCTAssertTrue(alert.informativeText.contains("Restarting Caloura"))
        XCTAssertEqual(
            alert.buttons.map(\.title),
            ["Restart Caloura", "Open System Settings", "Cancel"]
        )
    }

    func testMakePermissionAlert_confirmRepairRelaunchHasResetAndCancelButtons() {
        let alert = ScreenCaptureManager.makePermissionAlert(for: .confirmRepairRelaunch)

        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.messageText, "Reset Screen Recording permission?")
        XCTAssertTrue(alert.informativeText.contains("re-approve Caloura"))
        XCTAssertEqual(
            alert.buttons.map(\.title),
            ["Reset and Relaunch", "Cancel"]
        )
    }

    // MARK: - mapAlertResponse

    func testMapAlertResponse_neverGrantedFirstButtonOpensSettings() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertFirstButtonReturn,
                for: .neverGranted
            ),
            .openSystemSettings
        )
    }

    func testMapAlertResponse_neverGrantedSecondButtonCancels() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertSecondButtonReturn,
                for: .neverGranted
            ),
            .cancel
        )
    }

    func testMapAlertResponse_grantedButFailingFirstButtonRestarts() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertFirstButtonReturn,
                for: .grantedButFailing
            ),
            .restartApp
        )
    }

    func testMapAlertResponse_grantedButFailingSecondButtonOpensSettings() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertSecondButtonReturn,
                for: .grantedButFailing
            ),
            .openSystemSettings
        )
    }

    func testMapAlertResponse_grantedButFailingThirdButtonCancels() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertThirdButtonReturn,
                for: .grantedButFailing
            ),
            .cancel
        )
    }

    func testMapAlertResponse_confirmRepairRelaunchFirstButtonRestarts() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertFirstButtonReturn,
                for: .confirmRepairRelaunch
            ),
            .restartApp
        )
    }

    func testMapAlertResponse_confirmRepairRelaunchSecondButtonCancels() {
        XCTAssertEqual(
            ScreenCaptureManager.mapAlertResponse(
                .alertSecondButtonReturn,
                for: .confirmRepairRelaunch
            ),
            .cancel
        )
    }
}
