import Foundation

// Evidence acquisition + the convenience publishers shared by the passive
// paths and the serialized flows. All of them funnel into the gated
// `publishStatus`/`publish` path in `PermissionCoordinator.swift`.
extension PermissionCoordinator {
    /// Pure query. `updateUIModel` reassigns `permissionUIModel` from scratch
    /// using this value, and `scheduleCooldownReset` clears the model flag
    /// when the timer fires — so this method does not need a write side effect.
    func isCooldownActive(at timestamp: Date) -> Bool {
        store.isAlertCooldownActive(now: timestamp)
    }

    // MARK: - Evidence acquisition

    func refreshPassiveStatus(source: PublicationSource) async -> ScreenRecordingState {
        let identity = await identityProvider()
        let timestamp = now()
        let cgGranted = passiveCheck()
        let execPath = identity.executablePath
        let signingType = identity.signingIdentityType
        let passiveMsg = "passive_check cg_granted=\(cgGranted)"
            + " path=\(execPath) signing=\(signingType)"
        logger.info("\(passiveMsg, privacy: .public)")

        #if DEBUG
        if !cgGranted, identity.bundleIdentifier.contains(".debug") {
            let warnMsg = "Debug bundle ID '\(identity.bundleIdentifier)'"
                + " — System Settings toggle is for the release bundle ID"
            logger.warning("\(warnMsg, privacy: .public)")
        }
        #endif

        let status = PermissionStatusCore.passiveStatus(
            cgGranted: cgGranted,
            context: store.statusContext(for: identity, at: timestamp)
        )
        return publishStatus(status, identity: identity, source: source)
    }

    // MARK: - Convenience publishers

    @discardableResult
    func publishWorkingValidated(
        _ identity: PermissionIdentity,
        clearPermissionRequest: Bool = true,
        source: PublicationSource
    ) -> ScreenRecordingState {
        store.recordWorkingIdentity(identity)
        if clearPermissionRequest {
            store.clearRequestSession()
        }
        return publishStatus(.working, identity: identity, source: source)
    }

    @discardableResult
    func publishDenied(
        _ identity: PermissionIdentity,
        clearPermissionRequest: Bool = false,
        source: PublicationSource
    ) -> ScreenRecordingState {
        if clearPermissionRequest {
            store.clearRequestSession()
        }
        return publishStatus(.denied, identity: identity, source: source)
    }

    @discardableResult
    func publishExplicitFailure(
        for identity: PermissionIdentity,
        clearPermissionRequest: Bool = false,
        source: PublicationSource
    ) -> ScreenRecordingState {
        if clearPermissionRequest {
            store.clearRequestSession()
        }
        let status = PermissionStatusCore.explicitFailureStatus(
            for: store.statusContext(for: identity, at: now())
        )
        // Pin the hard diagnosis so passive refreshes cannot revert it (INVARIANT-5).
        if status == .needsRelaunch || status == .staleRecord {
            store.setDiagnosedFailure(
                PermissionStore.DiagnosedFailure(
                    identityFingerprint: identity.fingerprint,
                    status: status
                )
            )
        }
        return publishStatus(status, identity: identity, source: source)
    }
}
