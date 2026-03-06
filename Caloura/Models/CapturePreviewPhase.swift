import Foundation

enum CapturePreviewPhase: String, Equatable {
    case rawPreviewReady
    case enrichmentPending
    case enrichmentComplete
    case enrichmentFailed
}
