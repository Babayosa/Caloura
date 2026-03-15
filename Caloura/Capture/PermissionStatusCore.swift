import Foundation

struct PermissionStatusContext {
    let identity: PermissionIdentity
    let hasFreshPermissionRequest: Bool
    let hasLiveValidatedIdentity: Bool
    let isKnownWorkingIdentity: Bool
    let lastWorkingExecutablePathMatches: Bool
    let diagnosedFailureStatus: ScreenRecordingState?
    let hasKnownWorkingMismatch: Bool
    let didAutoRelaunchAfterRequest: Bool
}

enum PermissionStatusCore {
    static func passiveStatus(
        cgGranted: Bool,
        context: PermissionStatusContext
    ) -> ScreenRecordingState {
        if context.hasLiveValidatedIdentity {
            return .working
        }
        if !cgGranted {
            return context.hasFreshPermissionRequest
                ? .grantedNeedsValidation
                : .denied
        }
        if context.isKnownWorkingIdentity {
            return .working
        }
        if let diagnosedFailureStatus = context.diagnosedFailureStatus {
            return diagnosedFailureStatus
        }
        return .grantedNeedsValidation
    }

    static func explicitFailureStatus(
        for context: PermissionStatusContext
    ) -> ScreenRecordingState {
        guard context.hasKnownWorkingMismatch else {
            return .needsRelaunch
        }
        if context.lastWorkingExecutablePathMatches {
            // Same path but different fingerprint = in-place update.
            // Try validation before escalating — the TCC grant may still be valid.
            return .grantedNeedsValidation
        }
        return .staleRecord
    }

    static func uiModel(
        status: ScreenRecordingState,
        context: PermissionStatusContext,
        cooldownActive: Bool
    ) -> PermissionUIModel {
        PermissionUIModel(
            status: status,
            guidanceText: guidance(for: status, context: context),
            shouldShowStaleRecordBanner: status == .staleRecord,
            isAlertCooldownActive: cooldownActive
        )
    }

    static func nonBlockingMessage(for status: ScreenRecordingState) -> String {
        switch status {
        case .staleRecord:
            return "Screen Recording appears tied to a different Caloura copy. "
                + "Open /Applications/Caloura.app and try again."
        case .denied:
            return "Screen Recording permission required. Open System Settings to continue capturing."
        case .needsRelaunch:
            return "macOS still needs Caloura to relaunch before capture is available."
        case .grantedNeedsValidation, .working, .repairing:
            return "Screen Recording is still initializing. Try again in a moment."
        }
    }

    private static func guidance(
        for status: ScreenRecordingState,
        context: PermissionStatusContext
    ) -> String? {
        switch status {
        case .staleRecord:
            return "Current app: \(context.identity.executablePath)\n\n"
                + "macOS appears to trust a different Caloura copy. "
                + "In System Settings > Privacy > Screen Recording, remove the old Caloura entry, "
                + "then re-add /Applications/Caloura.app."
        case .needsRelaunch:
            return "Screen Recording is granted, but macOS needs a Caloura relaunch to fully apply it. "
                + "If restarting doesn't help, try logging out and back in."
        case .denied:
            return "Caloura needs Screen Recording access to capture screenshots."
        case .grantedNeedsValidation:
            if context.hasFreshPermissionRequest {
                return "Caloura is waiting for macOS to finish applying Screen Recording. "
                    + "Keep the toggle enabled and return here."
            }
            if context.isKnownWorkingIdentity || context.lastWorkingExecutablePathMatches {
                return "Caloura is re-validating Screen Recording for this app copy. "
                    + "Run one live capture check to finish confirming access."
            }
            return "Screen Recording looks granted. Start a capture to finish validation."
        case .repairing:
            if context.didAutoRelaunchAfterRequest {
                return "Restarting Caloura so macOS can finish applying Screen Recording."
            }
            return "Restarting screen recording service."
        case .working:
            return nil
        }
    }
}
