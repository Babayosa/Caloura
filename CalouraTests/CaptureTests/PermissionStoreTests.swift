import Foundation
import XCTest
@testable import Caloura

@MainActor
final class PermissionStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.caloura.tests.permission-store.\(UUID().uuidString)"
        guard let suiteDefaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create defaults suite: \(String(describing: suiteName))")
        }
        suiteDefaults.removePersistentDomain(forName: suiteName)
        defaults = suiteDefaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore(
        cooldownPolicy: PermissionCooldownPolicy = PermissionCooldownPolicy(),
        requestSessionLifetimeSeconds: TimeInterval = 180
    ) -> PermissionStore {
        PermissionStore(
            defaults: defaults,
            cooldownPolicy: cooldownPolicy,
            requestSessionLifetimeSeconds: requestSessionLifetimeSeconds
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Last working identity

    func testRecordWorkingIdentityPersistsLegacyKeysAndSetsLiveValidation() {
        let store = makeStore()
        let identity = PermissionTestHelpers.makeIdentity("record-working")
        store.setDiagnosedFailure(
            PermissionStore.DiagnosedFailure(
                identityFingerprint: identity.fingerprint,
                status: .needsRelaunch
            )
        )

        store.recordWorkingIdentity(identity)

        XCTAssertEqual(
            defaults.string(forKey: "permissionLastWorkingIdentityFingerprint"),
            identity.fingerprint,
            "Must persist under the pre-existing key — zero migration"
        )
        XCTAssertEqual(
            defaults.string(forKey: "permissionLastWorkingExecutablePath"),
            identity.executablePath
        )
        XCTAssertEqual(store.liveValidatedFingerprint, identity.fingerprint)
        XCTAssertNil(store.diagnosedFailure, "A working identity invalidates any pinned diagnosis")
    }

    func testLastWorkingIdentityRoundTrip() {
        let store = makeStore()
        let identity = PermissionTestHelpers.makeIdentity("round-trip")

        XCTAssertNil(store.lastWorkingIdentity().fingerprint)
        XCTAssertNil(store.lastWorkingIdentity().executablePath)

        store.recordWorkingIdentity(identity)
        let record = store.lastWorkingIdentity()

        XCTAssertEqual(record.fingerprint, identity.fingerprint)
        XCTAssertEqual(record.executablePath, identity.executablePath)
    }

    func testLastWorkingIdentityTreatsEmptyStringsAsAbsent() {
        defaults.set("", forKey: "permissionLastWorkingIdentityFingerprint")
        defaults.set("", forKey: "permissionLastWorkingExecutablePath")
        let store = makeStore()

        XCTAssertNil(store.lastWorkingIdentity().fingerprint)
        XCTAssertNil(store.lastWorkingIdentity().executablePath)
    }

    func testLastWorkingIdentityFieldsAreIndependent() {
        // Historical state can hold a path with no fingerprint; each field
        // must surface independently rather than gating on the other.
        defaults.set("/tmp/Caloura.app/Contents/MacOS/Caloura", forKey: "permissionLastWorkingExecutablePath")
        let store = makeStore()

        let record = store.lastWorkingIdentity()
        XCTAssertNil(record.fingerprint)
        XCTAssertEqual(record.executablePath, "/tmp/Caloura.app/Contents/MacOS/Caloura")
    }

    // MARK: - Pending capture resume

    func testArmPendingResumePersistsLegacyKeys() {
        let store = makeStore()

        store.armPendingResume(mode: .window, at: date(1_000))

        XCTAssertEqual(
            defaults.object(forKey: "permissionPendingCaptureResumeRequestedAt") as? Date,
            date(1_000)
        )
        XCTAssertEqual(defaults.string(forKey: "permissionPendingCaptureResumeMode"), "window")
    }

    func testTakePendingResumeIfFreshReturnsModeAndConsumes() {
        let store = makeStore()
        store.armPendingResume(mode: .fullscreen, at: date(2_000))

        let pending = store.takePendingResumeIfFresh(ttl: 120, now: date(2_100))

        XCTAssertEqual(pending?.mode, .fullscreen)
        XCTAssertEqual(pending?.requestedAt, date(2_000))
        XCTAssertNil(
            store.takePendingResumeIfFresh(ttl: 120, now: date(2_100)),
            "Take must be single-use"
        )
        XCTAssertNil(defaults.object(forKey: "permissionPendingCaptureResumeRequestedAt"))
        XCTAssertNil(defaults.string(forKey: "permissionPendingCaptureResumeMode"))
    }

    func testTakePendingResumeHonorsTTLBoundary() {
        let store = makeStore()
        store.armPendingResume(mode: .area, at: date(3_000))

        XCTAssertEqual(
            store.takePendingResumeIfFresh(ttl: 120, now: date(3_120))?.mode,
            .area,
            "Exactly at TTL is still fresh (<= semantics)"
        )

        store.armPendingResume(mode: .area, at: date(3_000))
        XCTAssertNil(
            store.takePendingResumeIfFresh(ttl: 120, now: date(3_121)),
            "One second past TTL is stale"
        )
        XCTAssertNil(
            defaults.object(forKey: "permissionPendingCaptureResumeRequestedAt"),
            "A stale take must still consume the persisted record"
        )
    }

    func testTakePendingResumeWithMalformedModeConsumesAndReturnsNil() {
        defaults.set(date(4_000), forKey: "permissionPendingCaptureResumeRequestedAt")
        defaults.set("not-a-mode", forKey: "permissionPendingCaptureResumeMode")
        let store = makeStore()

        XCTAssertNil(store.takePendingResumeIfFresh(ttl: 120, now: date(4_010)))
        XCTAssertNil(defaults.object(forKey: "permissionPendingCaptureResumeRequestedAt"))
    }

    func testPendingResumeModeIsNonConsuming() {
        let store = makeStore()
        store.armPendingResume(mode: .window, at: date(5_000))

        XCTAssertEqual(store.pendingResumeMode(), .window)
        XCTAssertEqual(store.pendingResumeMode(), .window, "Peek must not consume")
        XCTAssertEqual(store.takePendingResumeIfFresh(ttl: 120, now: date(5_001))?.mode, .window)
    }

    func testClearPendingResumeRemovesBothKeys() {
        let store = makeStore()
        store.armPendingResume(mode: .area, at: date(6_000))

        store.clearPendingResume()

        XCTAssertNil(defaults.object(forKey: "permissionPendingCaptureResumeRequestedAt"))
        XCTAssertNil(defaults.string(forKey: "permissionPendingCaptureResumeMode"))
        XCTAssertNil(store.takePendingResumeIfFresh(ttl: 120, now: date(6_001)))
    }

    // MARK: - Auto-repair relaunch cooldown

    func testCanAutoRepairRelaunchAllowsWhenNeverAttempted() {
        XCTAssertTrue(makeStore().canAutoRepairRelaunch(now: date(7_000)))
    }

    func testCanAutoRepairRelaunchBlocksWithinCooldownWindow() {
        let store = makeStore()
        store.markAutoRepairRelaunchAttempted(at: date(8_000))

        XCTAssertFalse(store.canAutoRepairRelaunch(now: date(8_030)))
        XCTAssertFalse(
            store.canAutoRepairRelaunch(now: date(8_060)),
            "Exactly at the 60s threshold is still blocked (strict > semantics)"
        )
        XCTAssertTrue(store.canAutoRepairRelaunch(now: date(8_061)))
        XCTAssertEqual(
            defaults.object(forKey: "permissionLastAutoRepairRelaunchAt") as? Date,
            date(8_000),
            "Must persist under the pre-existing key — zero migration"
        )
    }

    // MARK: - Blocking alert cooldown (persisted — the S1 behavior change)

    func testAlertCooldownActiveWithin45SecondsAndExpiresAfter() {
        let store = makeStore()
        XCTAssertFalse(store.isAlertCooldownActive(now: date(9_000)))

        store.noteBlockingAlertShown(at: date(9_000))

        XCTAssertTrue(store.isAlertCooldownActive(now: date(9_044)))
        XCTAssertFalse(
            store.isAlertCooldownActive(now: date(9_045)),
            "Exactly at the 45s threshold the cooldown has elapsed (strict < semantics)"
        )
    }

    func testAlertCooldownSurvivesSimulatedRelaunch() {
        // Pain-history phase 14: the 45s alert cooldown used to be
        // in-memory, so a relaunch reset it and the same blocking alert
        // could re-fire immediately. A new store instance on the same
        // defaults simulates the relaunch.
        let firstLaunch = makeStore()
        firstLaunch.noteBlockingAlertShown(at: date(10_000))

        let secondLaunch = makeStore()

        XCTAssertTrue(
            secondLaunch.isAlertCooldownActive(now: date(10_020)),
            "Cooldown must survive relaunch via the persisted timestamp"
        )
        XCTAssertFalse(secondLaunch.isAlertCooldownActive(now: date(10_100)))
        XCTAssertEqual(
            defaults.object(forKey: "permissionLastBlockingAlertAt") as? Date,
            date(10_000)
        )
    }

    func testAlertCooldownSecondsExposesPolicyThreshold() {
        let store = makeStore(cooldownPolicy: PermissionCooldownPolicy(alertCooldownSeconds: 10))
        XCTAssertEqual(store.alertCooldownSeconds, 10)
    }

    // MARK: - Request session

    func testBeginRequestSessionIsFreshWithinLifetime() {
        let store = makeStore()
        store.beginRequestSession(at: date(11_000))

        let session = store.activeRequestSession(now: date(11_180))
        XCTAssertEqual(session?.startedAt, date(11_000), "Exactly at 180s is still fresh (<= semantics)")
        XCTAssertEqual(session?.didAutoRelaunch, false)
    }

    func testActiveRequestSessionPrunesOnceExpired() {
        let store = makeStore()
        store.beginRequestSession(at: date(12_000))

        XCTAssertNil(store.activeRequestSession(now: date(12_181)))
        XCTAssertNil(store.requestSession, "Expired session must be pruned, not just hidden")
    }

    func testBeginRequestSessionWithDidAutoRelaunchSetsFlag() {
        let store = makeStore()
        store.beginRequestSession(at: date(13_000), didAutoRelaunch: true)

        XCTAssertEqual(store.activeRequestSession(now: date(13_001))?.didAutoRelaunch, true)
    }

    func testMarkRequestSessionAutoRelaunchedMutatesActiveSession() {
        let store = makeStore()
        store.beginRequestSession(at: date(14_000))

        store.markRequestSessionAutoRelaunched()

        XCTAssertEqual(store.requestSession?.didAutoRelaunch, true)
        XCTAssertEqual(store.requestSession?.startedAt, date(14_000))
    }

    func testMarkRequestSessionAutoRelaunchedNoOpsWithoutSession() {
        let store = makeStore()
        store.markRequestSessionAutoRelaunched()
        XCTAssertNil(store.requestSession)
    }

    func testClearRequestSession() {
        let store = makeStore()
        store.beginRequestSession(at: date(15_000))

        store.clearRequestSession()

        XCTAssertNil(store.requestSession)
        XCTAssertNil(store.activeRequestSession(now: date(15_001)))
    }

    // MARK: - Live validation

    func testRecordLiveValidationStoresFingerprintInMemoryOnly() {
        let store = makeStore()
        store.recordLiveValidation(fingerprint: "fp-live")

        XCTAssertEqual(store.liveValidatedFingerprint, "fp-live")
        XCTAssertNil(
            defaults.string(forKey: "permissionLastWorkingIdentityFingerprint"),
            "Live validation alone must not touch the durable working-identity record"
        )
        XCTAssertNil(
            makeStore().liveValidatedFingerprint,
            "Live validation is process-scoped — a new store starts clean"
        )
    }

    // MARK: - Diagnosed failure

    func testDiagnosedFailureSetAndClear() {
        let store = makeStore()
        let failure = PermissionStore.DiagnosedFailure(
            identityFingerprint: "fp-diagnosed",
            status: .staleRecord
        )

        store.setDiagnosedFailure(failure)
        XCTAssertEqual(store.diagnosedFailure, failure)

        store.clearDiagnosedFailure()
        XCTAssertNil(store.diagnosedFailure)
    }

    // MARK: - resetForIdentityChange scope

    func testResetForIdentityChangeClearsSessionScopedStateOnly() {
        let store = makeStore()
        let identity = PermissionTestHelpers.makeIdentity("reset-scope")
        store.recordWorkingIdentity(identity)
        store.armPendingResume(mode: .window, at: date(16_000))
        store.markAutoRepairRelaunchAttempted(at: date(16_000))
        store.noteBlockingAlertShown(at: date(16_000))
        store.beginRequestSession(at: date(16_000))
        store.setDiagnosedFailure(
            PermissionStore.DiagnosedFailure(
                identityFingerprint: identity.fingerprint,
                status: .needsRelaunch
            )
        )

        store.resetForIdentityChange()

        // Cleared: everything pinned to the old fingerprint or grant attempt.
        XCTAssertNil(store.liveValidatedFingerprint)
        XCTAssertNil(store.diagnosedFailure)
        XCTAssertNil(store.requestSession)

        // Preserved: lastWorkingIdentity feeds stale-record detection (it
        // must keep describing the OLD identity), pending resume survives
        // relaunch by design, and both cooldowns rate-limit the user.
        XCTAssertEqual(store.lastWorkingIdentity().fingerprint, identity.fingerprint)
        XCTAssertEqual(store.lastWorkingIdentity().executablePath, identity.executablePath)
        XCTAssertEqual(store.pendingResumeMode(), .window)
        XCTAssertFalse(store.canAutoRepairRelaunch(now: date(16_030)))
        XCTAssertTrue(store.isAlertCooldownActive(now: date(16_030)))
    }
}
