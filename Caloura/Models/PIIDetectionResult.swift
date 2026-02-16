import Foundation

struct PIIDetectionResult {
    let detections: [PIIDetection]
    let screenshotID: UUID
    let timestamp: Date

    init(detections: [PIIDetection], screenshotID: UUID, timestamp: Date = Date()) {
        self.detections = detections
        self.screenshotID = screenshotID
        self.timestamp = timestamp
    }
}
