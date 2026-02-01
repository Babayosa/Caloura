import Foundation

struct CaptureContext {
    let mode: CaptureMode
    let sourceAppName: String?
    let sourceWindowTitle: String?
    let timestamp: Date
    let screenIndex: Int

    init(
        mode: CaptureMode,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        timestamp: Date = Date(),
        screenIndex: Int = 0
    ) {
        self.mode = mode
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.timestamp = timestamp
        self.screenIndex = screenIndex
    }
}
