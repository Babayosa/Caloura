import Foundation

struct CaptureContext {
    let mode: CaptureMode
    let sourceAppName: String?
    let sourceWindowTitle: String?
    let timestamp: Date

    init(
        mode: CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        timestamp: Date = Date()
    ) {
        self.mode = mode
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.timestamp = timestamp
    }
}
