import Foundation

enum CaptureMode: String, Codable {
    case area
    case window
    case fullscreen

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = CaptureMode(rawValue: raw) ?? .area
    }
}
