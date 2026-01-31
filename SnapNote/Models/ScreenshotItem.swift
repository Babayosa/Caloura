import Foundation

struct ScreenshotItem: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let filePath: String
    let fileName: String
    let sourceAppName: String?
    let sourceWindowTitle: String?
    let captureMode: String
    let presetName: String?
    let ocrText: String?
    let width: Int
    let height: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        filePath: String,
        fileName: String,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        captureMode: String,
        presetName: String? = nil,
        ocrText: String? = nil,
        width: Int = 0,
        height: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.filePath = filePath
        self.fileName = fileName
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.captureMode = captureMode
        self.presetName = presetName
        self.ocrText = ocrText
        self.width = width
        self.height = height
    }
}
