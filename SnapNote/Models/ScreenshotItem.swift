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
    var title: String?
    var tags: [String]

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
        height: Int = 0,
        title: String? = nil,
        tags: [String] = []
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
        self.title = title
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        filePath = try container.decode(String.self, forKey: .filePath)
        fileName = try container.decode(String.self, forKey: .fileName)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceWindowTitle = try container.decodeIfPresent(String.self, forKey: .sourceWindowTitle)
        captureMode = try container.decode(String.self, forKey: .captureMode)
        presetName = try container.decodeIfPresent(String.self, forKey: .presetName)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}
