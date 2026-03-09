import Foundation
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import Caloura

@MainActor
final class ScreenCaptureManagerPermissionTests: XCTestCase {

    func testCheckPermission_usesInjectedPreflightResult() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(preflight: { true })
        )

        XCTAssertTrue(manager.checkPermission())
    }

    func testRequestPermission_usesInjectedRequester() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(request: { true })
        )

        XCTAssertTrue(manager.requestPermission())
    }

    func testCheckSCKAccess_successClearsFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                sckProbe: { .authorized }
            )
        )
        manager.setSCKFailedForTesting(true)

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .authorized)
        XCTAssertFalse(manager.sckFailed)
    }

    func testCheckSCKAccess_userDeclinedSetsFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                sckProbe: { .userDeclined }
            )
        )

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .userDeclined)
        XCTAssertTrue(manager.sckFailed)
    }

    func testPrimeSCKAccessIfPossible_failureDoesNotSetFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                sckProbe: { .transientFailure }
            )
        )

        let result = await manager.primeSCKAccessIfPossible()

        XCTAssertEqual(result, .transientFailure)
        XCTAssertFalse(manager.sckFailed)
    }

    func testValidateSCKAccessUserInitiated_delegatesToCheckSCKAccess() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                sckProbe: { .authorized }
            )
        )

        let result = await manager.validateSCKAccessUserInitiated()

        XCTAssertEqual(result, .authorized)
        XCTAssertFalse(manager.sckFailed)
    }

    func testCoreGraphicsPermissionFailureCheckCanBeSuppressedDuringRecentGrantWindow() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(preflight: { false }),
            cgPreflightAuthorityProvider: { false }
        )

        XCTAssertFalse(manager.shouldTreatCoreGraphicsStateAsPermissionDenied())
        XCTAssertFalse(
            manager.shouldTreatCaptureErrorAsPermissionDenied(
                NSError(domain: "tests", code: 1)
            )
        )
    }

    func testCoreGraphicsPermissionFailureCheckStillAppliesWhenAuthoritative() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(preflight: { false }),
            cgPreflightAuthorityProvider: { true }
        )

        XCTAssertTrue(manager.shouldTreatCoreGraphicsStateAsPermissionDenied())
        XCTAssertTrue(
            manager.shouldTreatCaptureErrorAsPermissionDenied(
                NSError(domain: "tests", code: 1)
            )
        )
    }

    func testSCKUserDeclinedMapsToPermissionDeniedWithoutCoreGraphicsFallback() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(preflight: { true }),
            cgPreflightAuthorityProvider: { false }
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        XCTAssertTrue(manager.shouldTreatCaptureErrorAsPermissionDenied(error))
    }

    func testRepairSCKAccess_runsRepairToolAndRechecksAuthorization() async {
        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                box: box,
                sckProbe: {
                    if box.runRepairToolCalls.isEmpty {
                        return .transientFailure
                    }
                    return .authorized
                }
            )
        )

        let result = await manager.repairSCKAccess()

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(box.runRepairToolCalls.count, 1)
        XCTAssertEqual(box.runRepairToolCalls.first?.0.lastPathComponent, "launchctl")
    }

    func testResetTCCEntry_runsTCCUtility() async {
        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(box: box)
        )

        await manager.resetTCCEntry()

        XCTAssertEqual(box.runRepairToolCalls.count, 1)
        XCTAssertEqual(box.runRepairToolCalls.first?.0.lastPathComponent, "tccutil")
    }

    func testRelaunchApp_successTerminatesApplication() async {
        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(box: box)
        )
        let expectation = expectation(description: "terminate called")
        box.onTerminate = {
            expectation.fulfill()
        }

        manager.relaunchApp()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testRelaunchApp_failureUpdatesStatusMessage() async {
        let originalStatus = AppState.shared.statusMessage
        addTeardownBlock { @MainActor in
            AppState.shared.statusMessage = originalStatus
        }

        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                box: box,
                relaunchResult: .failure(NSError(
                    domain: "tests",
                    code: 77,
                    userInfo: [NSLocalizedDescriptionKey: "boom"]
                ))
            )
        )
        AppState.shared.statusMessage = ""

        manager.relaunchApp()
        await pollUntil { AppState.shared.statusMessage == "Restart failed: boom" }

        XCTAssertEqual(AppState.shared.statusMessage, "Restart failed: boom")
    }

    func testShowPermissionAlert_neverGrantedOpensSettings() {
        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                box: box,
                alertAction: .openSystemSettings
            )
        )

        manager.showPermissionAlert(for: .neverGranted)

        XCTAssertEqual(box.openedURLs.count, 1)
        XCTAssertTrue(box.openedURLs[0].absoluteString.contains("Privacy_ScreenCapture"))
    }

    func testShowPermissionAlert_grantedButFailingRestartRelaunchesAndTerminates() async {
        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                box: box,
                alertAction: .restartApp
            )
        )
        let expectation = expectation(description: "terminate called")
        box.onTerminate = {
            expectation.fulfill()
        }

        manager.showPermissionAlert(for: .grantedButFailing)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(box.runRepairToolCalls.isEmpty)
    }

    func testShowPermissionAlert_grantedButFailingOpenSettingsUsesURLHandler() {
        let box = DependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makeDependencies(
                box: box,
                alertAction: .openSystemSettings
            )
        )

        manager.showPermissionAlert(for: .grantedButFailing)

        XCTAssertEqual(box.openedURLs.count, 1)
    }

    func testRunRepairTool_successfulCommandReturns() async throws {
        try await ScreenCaptureManager.runRepairTool(
            URL(filePath: "/usr/bin/true"),
            arguments: []
        )
    }

    func testRunRepairTool_failureIncludesToolAndExitStatus() async {
        do {
            try await ScreenCaptureManager.runRepairTool(
                URL(filePath: "/usr/bin/false"),
                arguments: []
            )
            XCTFail("Expected repair tool to fail")
        } catch let error as PermissionRepairProcessError {
            XCTAssertEqual(error.tool, "false")
            XCTAssertEqual(error.status, 1)
            XCTAssertTrue(error.errorDescription?.contains("false exited with status 1") == true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeDependencies(
        box: DependencyBox = DependencyBox(),
        preflight: @escaping @Sendable () -> Bool = { true },
        request: @escaping @Sendable () -> Bool = { false },
        sckProbe: @escaping @Sendable () async -> ScreenCaptureAccessProbeResult = {
            .authorized
        },
        alertAction: ScreenCapturePermissionAlertAction = .cancel,
        relaunchResult: Result<Void, Error> = .success(())
    ) -> ScreenCapturePermissionDependencies {
        ScreenCapturePermissionDependencies(
            cgPreflight: preflight,
            cgRequest: request,
            sckAccessProbe: sckProbe,
            runRepairTool: { url, arguments in
                box.runRepairToolCalls.append((url, arguments))
            },
            presentAlert: { _ in
                alertAction
            },
            openURL: { url in
                box.openedURLs.append(url)
            },
            relaunchApplication: { _ in
                try relaunchResult.get()
            },
            terminateApplication: {
                box.terminateCount += 1
                box.onTerminate?()
            }
        )
    }
}

private final class DependencyBox: @unchecked Sendable {
    var runRepairToolCalls: [(URL, [String])] = []
    var openedURLs: [URL] = []
    var terminateCount = 0
    var onTerminate: (() -> Void)?
}
