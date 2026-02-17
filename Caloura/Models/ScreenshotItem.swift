import Foundation

struct ScreenshotItem: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    var filePath: String
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
    let schemaVersion: Int

    // Schema v2 fields (AI features)
    var smartFileName: String?
    var summary: String?
    var autoTags: [String]
    var embeddingVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, filePath, fileName
        case sourceAppName, sourceWindowTitle
        case captureMode, presetName, ocrText
        case width, height, title, tags
        case schemaVersion
        case smartFileName, summary, autoTags, embeddingVersion
    }

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
        tags: [String] = [],
        schemaVersion: Int = 2,
        smartFileName: String? = nil,
        summary: String? = nil,
        autoTags: [String] = [],
        embeddingVersion: Int? = nil
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
        self.schemaVersion = schemaVersion
        self.smartFileName = smartFileName
        self.summary = summary
        self.autoTags = autoTags
        self.embeddingVersion = embeddingVersion
    }

    static func == (lhs: ScreenshotItem, rhs: ScreenshotItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        smartFileName = try container.decodeIfPresent(String.self, forKey: .smartFileName)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        autoTags = try container.decodeIfPresent([String].self, forKey: .autoTags) ?? []
        embeddingVersion = try container.decodeIfPresent(Int.self, forKey: .embeddingVersion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try container.encodeIfPresent(sourceWindowTitle, forKey: .sourceWindowTitle)
        try container.encode(captureMode, forKey: .captureMode)
        try container.encodeIfPresent(presetName, forKey: .presetName)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(tags, forKey: .tags)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(smartFileName, forKey: .smartFileName)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(autoTags, forKey: .autoTags)
        try container.encodeIfPresent(embeddingVersion, forKey: .embeddingVersion)
    }
}
