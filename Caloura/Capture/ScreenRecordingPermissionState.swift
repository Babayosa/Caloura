import Foundation

/// Published Screen Recording permission state shared by the coordinator,
/// `PermissionStatusCore`, `PermissionStore`, and the recovery planner.
enum ScreenRecordingState: Equatable {
    case denied
    case grantedNeedsValidation
    case working
    case needsRelaunch
    case staleRecord
    case repairing
    case configurationFailed
}

struct PermissionUIModel: Equatable {
    var status: ScreenRecordingState = .grantedNeedsValidation
    var guidanceText: String?
    var shouldShowStaleRecordBanner: Bool = false
    var isAlertCooldownActive: Bool = false
}
