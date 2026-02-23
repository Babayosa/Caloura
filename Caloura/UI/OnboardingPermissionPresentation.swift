import Foundation

enum PermissionDetail: Equatable {
    case working
    case grantedNotWorking
    case notGranted
    case signatureMismatch
    case repairing
}

struct OnboardingPermissionPresentation: Equatable {
    let detail: PermissionDetail
    let shouldShowMismatchBanner: Bool
    let showsGrantButton: Bool
    let showsCheckAgainButton: Bool
    let showsRepairButton: Bool
    let showsResetRelaunchButton: Bool
    let statusHeadline: String
    let statusMessage: String

    static func from(_ uiModel: PermissionUIModel) -> OnboardingPermissionPresentation {
        let detail: PermissionDetail
        switch uiModel.status {
        case .grantedWorking:
            detail = .working
        case .grantedNeedsRelaunch:
            detail = .grantedNotWorking
        case .signatureMismatch:
            detail = .signatureMismatch
        case .repairing:
            detail = .repairing
        case .denied, .unknown:
            detail = .notGranted
        }

        let statusHeadline: String
        let statusMessage: String
        let showsGrantButton: Bool
        let showsRepairButton: Bool
        let showsResetRelaunchButton: Bool

        switch detail {
        case .working:
            statusHeadline = "Permission granted"
            statusMessage = "You're ready to capture screenshots."
            showsGrantButton = false
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .grantedNotWorking:
            statusHeadline = "Permission needs repair"
            statusMessage = uiModel.guidanceText ?? "Relaunch Caloura to finish applying access."
            showsGrantButton = false
            showsRepairButton = true
            showsResetRelaunchButton = true
        case .notGranted:
            statusHeadline = "Permission not granted yet"
            statusMessage = "You can continue now and grant this anytime."
            showsGrantButton = true
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .signatureMismatch:
            statusHeadline = "Permission tied to a different build"
            statusMessage = uiModel.guidanceText ?? "Use /Applications/Caloura.app or re-grant for this build."
            showsGrantButton = true
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .repairing:
            statusHeadline = "Repairing..."
            statusMessage = uiModel.guidanceText ?? "Restarting screen recording service."
            showsGrantButton = false
            showsRepairButton = false
            showsResetRelaunchButton = false
        }

        return OnboardingPermissionPresentation(
            detail: detail,
            shouldShowMismatchBanner: uiModel.shouldShowSignatureMismatchBanner,
            showsGrantButton: showsGrantButton,
            showsCheckAgainButton: detail != .repairing,
            showsRepairButton: showsRepairButton,
            showsResetRelaunchButton: showsResetRelaunchButton,
            statusHeadline: statusHeadline,
            statusMessage: statusMessage
        )
    }
}
