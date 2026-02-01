import Foundation

enum CaptureMode: String, Codable, CaseIterable {
    case area = "area"
    case window = "window"
    case fullscreen = "fullscreen"

    var displayName: String {
        switch self {
        case .area: return "Selected Area"
        case .window: return "Window"
        case .fullscreen: return "Full Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        }
    }
}
