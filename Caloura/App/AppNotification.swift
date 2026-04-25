import Foundation

extension Notification.Name {
    static let captureCompleted = Notification.Name("captureCompleted")
}

enum AppNotificationUserInfoKey {
    static let captureRequestID = "captureRequestID"
}
