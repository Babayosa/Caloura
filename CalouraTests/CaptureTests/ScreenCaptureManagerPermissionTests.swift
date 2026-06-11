import Foundation
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import Caloura

@MainActor
final class ScreenCaptureManagerPermissionTests: XCTestCase {
    func testCheckPermission_usesInjectedPreflightResult() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(preflight: { true })
        )

        XCTAssertTrue(manager.checkPermission())
    }

    func testRequestPermission_usesInjectedRequester() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(request: { true })
        )

        XCTAssertTrue(manager.requestPermission())
    }

    func testPassivePermissionGranted_delegatesToCheckPermission() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(preflight: { false })
        )

        XCTAssertFalse(manager.passivePermissionGranted())
    }

    func testCheckSCKAccess_successClearsFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
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
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .userDeclined }
            )
        )

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .userDeclined)
        XCTAssertTrue(manager.sckFailed)
    }

    func testCheckSCKAccess_transientFailureIncrementsCounterWithoutDisabling() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .transientFailure }
            )
        )

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .transientFailure)
        XCTAssertEqual(manager.sckFailureCount, 1)
        XCTAssertFalse(manager.sckFailed)
    }

    func testCheckSCKAccess_transientFailureAtThresholdDisablesSCK() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .transientFailure }
            )
        )
        manager.sckFailureCount = manager.maxTransientFailures - 1

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .transientFailure)
        XCTAssertEqual(manager.sckFailureCount, manager.maxTransientFailures)
        XCTAssertTrue(manager.sckFailed)
    }

    func testCheckSCKAccess_authorizedResetsTransientFailureCount() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .authorized }
            )
        )
        manager.sckFailureCount = 2
        manager.setSCKFailedForTesting(true)

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(manager.sckFailureCount, 0)
        XCTAssertFalse(manager.sckFailed)
    }

    func testPrimeSCKAccessIfPossible_failureDoesNotSetFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .transientFailure }
            )
        )

        let result = await manager.primeSCKAccessIfPossible()

        XCTAssertEqual(result, .transientFailure)
        XCTAssertFalse(manager.sckFailed)
    }

    func testValidateSCKAccessUserInitiated_delegatesToCheckSCKAccess() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .authorized }
            )
        )

        let result = await manager.validateSCKAccessUserInitiated()

        XCTAssertEqual(result, .authorized)
        XCTAssertFalse(manager.sckFailed)
    }

    func testCoreGraphicsPermissionFailureCheckCanBeSuppressedDuringRecentGrantWindow() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(preflight: { false }),
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
            permissionDependencies: makePermissionDependencies(preflight: { false }),
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
            permissionDependencies: makePermissionDependencies(preflight: { true }),
            cgPreflightAuthorityProvider: { false }
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        XCTAssertTrue(manager.shouldTreatCaptureErrorAsPermissionDenied(error))
    }

    func testRepairSCKAccess_runsRepairToolAndRechecksAuthorization() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
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

    func testRepairSCKAccess_repairToolFailureReturnsTransientFailure() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                runRepairTool: { _, _ in
                    throw NSError(
                        domain: "tests",
                        code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "repair failed"]
                    )
                }
            )
        )

        let result = await manager.repairSCKAccess()

        XCTAssertEqual(result, .transientFailure)
    }

    func testResetTCCEntry_runsTCCUtility() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(box: box)
        )

        let result = await manager.resetTCCEntry()

        XCTAssertTrue(result)
        XCTAssertEqual(box.runRepairToolCalls.count, 1)
        XCTAssertEqual(box.runRepairToolCalls.first?.0.lastPathComponent, "tccutil")
    }

    func testResetTCCEntry_failureDoesNotThrow() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                runRepairTool: { _, _ in
                    throw NSError(
                        domain: "tests",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "tcc reset failed"]
                    )
                }
            )
        )

        let result = await manager.resetTCCEntry()

        XCTAssertFalse(result)
        XCTAssertEqual(box.runRepairToolCalls.count, 0)
    }

    func testRelaunchApp_successTerminatesApplication() async {
        let box = PermissionDependencyBox()
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(box: box)
        )
        let expectation = expectation(description: "terminate called")
        box.onTerminate = {
            expectation.fulfill()
        }

        manager.relaunchApp()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testRelaunchApp_failureUpdatesStatusMessage() async {
        let box = PermissionDependencyBox()
        var capturedMessage = ""
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                box: box,
                relaunchResult: .failure(NSError(
                    domain: "tests",
                    code: 77,
                    userInfo: [NSLocalizedDescriptionKey: "boom"]
                )),
                statusMessageSink: { capturedMessage = $0 }
            )
        )

        manager.relaunchApp()
        await pollUntil(timeout: 5.0) {
            capturedMessage == "Restart failed: boom"
        }

        XCTAssertEqual(capturedMessage, "Restart failed: boom")
    }

    func testCheckSCKAccess_configurationFailureSetsMissingEntitlements() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .configurationFailure }
            )
        )

        let result = await manager.checkSCKAccess()

        XCTAssertEqual(result, .configurationFailure)
        XCTAssertTrue(manager.sckFailed)
        XCTAssertEqual(manager.sckDisableReason, .missingEntitlements)
    }

    func testPrimeSCKAccessIfPossible_configurationFailureDoesNotSetFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .configurationFailure }
            )
        )

        let result = await manager.primeSCKAccessIfPossible()

        XCTAssertEqual(result, .configurationFailure)
        XCTAssertFalse(manager.sckFailed)
    }

    func testPrimeSCKAccessIfPossible_userDeclinedDoesNotSetFailureState() async {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(
                sckProbe: { .userDeclined }
            )
        )

        let result = await manager.primeSCKAccessIfPossible()

        XCTAssertEqual(result, .userDeclined)
        XCTAssertFalse(manager.sckFailed)
    }

    // MARK: - classifySCKError

    func testClassifySCKError_userDeclinedReturnsPermissionDenied() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )
        XCTAssertEqual(manager.classifySCKError(error), .permissionDenied)
    }

    func testClassifySCKError_systemStoppedStreamReturnsSystemStopped() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.systemStoppedStream.rawValue
        )
        XCTAssertEqual(manager.classifySCKError(error), .systemStopped)
    }

    func testClassifySCKError_missingEntitlementsReturnsMissingEntitlements() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.missingEntitlements.rawValue
        )
        XCTAssertEqual(manager.classifySCKError(error), .missingEntitlements)
    }

    func testClassifySCKError_unknownSCKCodeReturnsTransient() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.internalError.rawValue
        )
        XCTAssertEqual(manager.classifySCKError(error), .transient)
    }

    func testClassifySCKError_nonSCKDomainReturnsTransient() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(domain: "tests", code: 1)
        XCTAssertEqual(manager.classifySCKError(error), .transient)
    }

    func testHandleSCKFailure_missingEntitlementsPermanentlyDisables() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.missingEntitlements.rawValue
        )
        manager.handleSCKFailure(error)
        XCTAssertTrue(manager.sckFailed)
        XCTAssertEqual(manager.sckDisableReason, .missingEntitlements)
    }

    func testMinimalSCKProbeMissingEntitlementsReturnsConfigurationFailure() async {
        let result = await ScreenCaptureManager.probeSCKAccessViaMinimalScreenshot(
            displayBoundsProvider: {
                CGRect(x: 0, y: 0, width: 20, height: 20)
            },
            screenshotProbe: { _ in
                throw NSError(
                    domain: SCStreamError.errorDomain,
                    code: SCStreamError.Code.missingEntitlements.rawValue
                )
            }
        )

        XCTAssertEqual(result, .configurationFailure)
    }

    func testHandleSCKFailure_systemStoppedDoesNotDisable() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies()
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.systemStoppedStream.rawValue
        )
        manager.handleSCKFailure(error)
        XCTAssertFalse(manager.sckFailed)
        XCTAssertEqual(manager.sckFailureCount, 0)
    }

    func testShouldTreatCaptureError_systemStoppedIsNotPermissionDenied() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(preflight: { false }),
            cgPreflightAuthorityProvider: { true }
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.systemStoppedStream.rawValue
        )
        XCTAssertFalse(manager.shouldTreatCaptureErrorAsPermissionDenied(error))
    }

    func testShouldTreatCaptureError_missingEntitlementsIsNotPermissionDenied() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(preflight: { true }),
            cgPreflightAuthorityProvider: { false }
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.missingEntitlements.rawValue
        )
        XCTAssertFalse(manager.shouldTreatCaptureErrorAsPermissionDenied(error))
    }

    func testCaptureErrorForSCKFailure_missingEntitlementsReturnsConfigurationFailure() {
        let manager = ScreenCaptureManager(
            permissionDependencies: makePermissionDependencies(preflight: { true }),
            cgPreflightAuthorityProvider: { false }
        )
        let error = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.missingEntitlements.rawValue
        )

        let captureError = manager.captureErrorForSCKFailure(error)

        guard case .configurationFailed = captureError else {
            return XCTFail("Expected configurationFailed, got \(String(describing: captureError))")
        }
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
}
