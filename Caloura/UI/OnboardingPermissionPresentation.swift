import Foundation

enum PermissionDetail: Equatable {
    case working
    case grantedNotWorking
    case notGranted
    case signatureMismatch
}

struct OnboardingPermissionPresentation: Equatable {
    let detail: PermissionDetail
    let shouldShowMismatchBanner: Bool
    let showsGrantButton: Bool
    let showsCheckAgainButton: Bool
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
        case .denied, .unknown:
            detail = .notGranted
        }

        let statusHeadline: String
        let statusMessage: String
        let showsGrantButton: Bool

        switch detail {
        case .working:
            statusHeadline = "Permission granted"
            statusMessage = "You're ready to capture screenshots."
            showsGrantButton = false
        case .grantedNotWorking:
            statusHeadline = "Permission granted"
            statusMessage = uiModel.guidanceText ?? "Relaunch Caloura to finish applying access."
            showsGrantButton = false
        case .notGranted:
            statusHeadline = "Permission not granted yet"
            statusMessage = "You can continue now and grant this anytime."
            showsGrantButton = true
        case .signatureMismatch:
            statusHeadline = "Permission tied to a different build"
            statusMessage = uiModel.guidanceText ?? "Use /Applications/Caloura.app or re-grant for this build."
            showsGrantButton = true
        }

        return OnboardingPermissionPresentation(
            detail: detail,
            shouldShowMismatchBanner: uiModel.shouldShowSignatureMismatchBanner,
            showsGrantButton: showsGrantButton,
            showsCheckAgainButton: true,
            statusHeadline: statusHeadline,
            statusMessage: statusMessage
        )
    }
}
