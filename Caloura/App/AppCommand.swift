import Foundation

enum AppCommand: Equatable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureRepeat
    case captureDelayed(mode: CaptureMode, seconds: Int)
    case cancelDelayedCapture
    case captureScroll
    case copyLastImage
    case copyLastAsMarkdown
    case copyLastWithCitation
    case copyLastOCRText
    case annotateLastCapture
    case pinScreenshot
    case beautifyLastCapture
    case redactLastCapture
    case showHistory
    case showSettings
    case showPermissionRepair
}

@MainActor
final class AppCommandRouter {
    static let shared = AppCommandRouter()

    typealias Handler = @MainActor (AppCommand) -> Void

    private var handlers: [UUID: Handler] = [:]

    private init() {}

    @discardableResult
    func addHandler(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func removeHandler(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func dispatch(_ command: AppCommand) {
        let currentHandlers = handlers.values
        for handler in currentHandlers {
            handler(command)
        }
    }
}
