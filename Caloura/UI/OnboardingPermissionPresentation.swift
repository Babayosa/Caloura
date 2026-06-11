import Foundation

enum PermissionDetail: Equatable {
    case working
    case grantedNeedsValidation
    case needsRelaunch
    case notGranted
    case staleRecord
    case repairing
    case configurationFailed
}

struct OnboardingPermissionPresentation: Equatable {
    let detail: PermissionDetail
    let shouldShowStaleRecordBanner: Bool
    let showsGrantButton: Bool
    let showsCheckAgainButton: Bool
    let showsRepairButton: Bool
    let showsResetRelaunchButton: Bool
    let statusHeadline: String
    let statusMessage: String

    static func from(_ uiModel: PermissionUIModel) -> OnboardingPermissionPresentation {
        let detail: PermissionDetail
        switch uiModel.status {
        case .working:
            detail = .working
        case .grantedNeedsValidation:
            detail = .grantedNeedsValidation
        case .needsRelaunch:
            detail = .needsRelaunch
        case .staleRecord:
            detail = .staleRecord
        case .repairing:
            detail = .repairing
        case .configurationFailed:
            detail = .configurationFailed
        case .denied:
            detail = .notGranted
        }

        let statusHeadline: String
        let statusMessage: String
        let showsGrantButton: Bool
        let showsCheckAgainButton: Bool
        let showsRepairButton: Bool
        let showsResetRelaunchButton: Bool

        switch detail {
        case .working:
            statusHeadline = "Screen Recording ready"
            statusMessage = "Caloura is ready to capture screenshots."
            showsGrantButton = false
            showsCheckAgainButton = false
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .grantedNeedsValidation:
            statusHeadline = "Finish validation with a capture"
            statusMessage = uiModel.guidanceText ?? "Start a capture to confirm Screen Recording is fully available."
            showsGrantButton = false
            showsCheckAgainButton = true
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .needsRelaunch:
            statusHeadline = "One relaunch still needed"
            statusMessage = uiModel.guidanceText ?? "Relaunch Caloura to finish applying Screen Recording access."
            showsGrantButton = false
            showsCheckAgainButton = false
            showsRepairButton = true
            showsResetRelaunchButton = true
        case .notGranted:
            statusHeadline = "Screen Recording not granted yet"
            statusMessage = uiModel.guidanceText ?? "Grant Screen Recording when you take your first screenshot."
            showsGrantButton = true
            showsCheckAgainButton = false
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .staleRecord:
            statusHeadline = "macOS trusts a different Caloura copy"
            statusMessage = uiModel.guidanceText
                ?? "Use /Applications/Caloura.app, then refresh Screen Recording for that copy."
            showsGrantButton = false
            showsCheckAgainButton = true
            showsRepairButton = true
            showsResetRelaunchButton = true
        case .repairing:
            statusHeadline = "Repairing Screen Recording"
            statusMessage = uiModel.guidanceText ?? "Restarting the screen recording service."
            showsGrantButton = false
            showsCheckAgainButton = false
            showsRepairButton = false
            showsResetRelaunchButton = false
        case .configurationFailed:
            statusHeadline = "Screen capture unavailable"
            statusMessage = uiModel.guidanceText ?? "Launch the signed Caloura app or reinstall it."
            showsGrantButton = false
            showsCheckAgainButton = true
            showsRepairButton = false
            showsResetRelaunchButton = false
        }

        return OnboardingPermissionPresentation(
            detail: detail,
            shouldShowStaleRecordBanner: uiModel.shouldShowStaleRecordBanner,
            showsGrantButton: showsGrantButton,
            showsCheckAgainButton: showsCheckAgainButton,
            showsRepairButton: showsRepairButton,
            showsResetRelaunchButton: showsResetRelaunchButton,
            statusHeadline: statusHeadline,
            statusMessage: statusMessage
        )
    }
}
