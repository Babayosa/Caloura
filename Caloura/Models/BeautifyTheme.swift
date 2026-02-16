import CoreGraphics
import Foundation

struct CodableColor: Codable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

struct BeautifyTheme: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var gradientColors: [CodableColor]
    var gradientAngle: Double
    var cornerRadius: CGFloat
    var padding: CGFloat
    var shadowRadius: CGFloat
    var shadowOpacity: Double
    var shadowOffset: CGSize

    static let builtInThemes: [BeautifyTheme] = [
        BeautifyTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Clean",
            gradientColors: [
                CodableColor(red: 0.95, green: 0.95, blue: 0.97),
                CodableColor(red: 0.90, green: 0.90, blue: 0.93)
            ],
            gradientAngle: 180,
            cornerRadius: 10,
            padding: 40,
            shadowRadius: 20,
            shadowOpacity: 0.3,
            shadowOffset: CGSize(width: 0, height: 4)
        ),
        BeautifyTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Ocean",
            gradientColors: [
                CodableColor(red: 0.11, green: 0.56, blue: 0.85),
                CodableColor(red: 0.05, green: 0.27, blue: 0.53)
            ],
            gradientAngle: 135,
            cornerRadius: 12,
            padding: 48,
            shadowRadius: 24,
            shadowOpacity: 0.4,
            shadowOffset: CGSize(width: 0, height: 6)
        ),
        BeautifyTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Sunset",
            gradientColors: [
                CodableColor(red: 1.0, green: 0.60, blue: 0.30),
                CodableColor(red: 0.90, green: 0.25, blue: 0.40)
            ],
            gradientAngle: 135,
            cornerRadius: 12,
            padding: 48,
            shadowRadius: 24,
            shadowOpacity: 0.35,
            shadowOffset: CGSize(width: 0, height: 6)
        ),
        BeautifyTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Midnight",
            gradientColors: [
                CodableColor(red: 0.12, green: 0.12, blue: 0.18),
                CodableColor(red: 0.05, green: 0.05, blue: 0.10)
            ],
            gradientAngle: 180,
            cornerRadius: 10,
            padding: 40,
            shadowRadius: 20,
            shadowOpacity: 0.5,
            shadowOffset: CGSize(width: 0, height: 4)
        ),
        BeautifyTheme(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Neon",
            gradientColors: [
                CodableColor(red: 0.58, green: 0.0, blue: 0.83),
                CodableColor(red: 0.0, green: 0.80, blue: 0.85),
                CodableColor(red: 0.0, green: 0.95, blue: 0.55)
            ],
            gradientAngle: 135,
            cornerRadius: 14,
            padding: 52,
            shadowRadius: 28,
            shadowOpacity: 0.4,
            shadowOffset: CGSize(width: 0, height: 8)
        )
    ]

    static func theme(named name: String) -> BeautifyTheme? {
        builtInThemes.first { $0.name == name }
    }
}
