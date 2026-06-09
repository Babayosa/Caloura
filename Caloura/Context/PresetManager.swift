import Foundation

enum CopyMode: String, Codable {
    case image = "Image"
    case markdown = "Markdown"
    case citation = "Citation"
    case multiFormat = "Multi-Format"
}

struct CapturePreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var smartCropEnabled: Bool
    var copyMode: CopyMode
    var subfolder: String?
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        smartCropEnabled: Bool = true,
        copyMode: CopyMode = .image,
        subfolder: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.smartCropEnabled = smartCropEnabled
        self.copyMode = copyMode
        self.subfolder = subfolder
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - Resilient Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, smartCropEnabled, copyMode, subfolder, isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        smartCropEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartCropEnabled) ?? true
        copyMode = try container.decodeIfPresent(CopyMode.self, forKey: .copyMode) ?? .image
        subfolder = try container.decodeIfPresent(String.self, forKey: .subfolder)
        // Defense-in-depth: reject path traversal attempts at deserialization
        if let sub = subfolder, sub.contains("..") {
            subfolder = nil
        }
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

@MainActor
@Observable
final class PresetManager {
    static let shared = PresetManager()
    static let builtInPresetNames = ["Quick Capture", "Lecture Notes", "Code Snippet", "Assignment"]

    var presets: [CapturePreset] = [] {
        didSet {
            guard !isInitializing else { return }
            savePresets()
        }
    }

    private let defaults: UserDefaults
    private let presetsKey = "capturePresets"
    private var isInitializing = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPresets()
        ensureBuiltInPresets()
        isInitializing = false
        savePresets()
    }

    // MARK: - Built-in Presets

    private static let builtInPresets: [CapturePreset] = [
        CapturePreset(
            name: "Quick Capture",
            smartCropEnabled: false,
            copyMode: .image,
            subfolder: nil,
            isBuiltIn: true
        ),
        CapturePreset(
            name: "Lecture Notes",
            smartCropEnabled: true,
            copyMode: .citation,
            subfolder: "Lectures",
            isBuiltIn: true
        ),
        CapturePreset(
            name: "Code Snippet",
            smartCropEnabled: false,
            copyMode: .image,
            subfolder: "Code",
            isBuiltIn: true
        ),
        CapturePreset(
            name: "Assignment",
            smartCropEnabled: true,
            copyMode: .multiFormat,
            subfolder: "Assignments",
            isBuiltIn: true
        )
    ]

    // MARK: - Lookup

    func preset(named name: String) -> CapturePreset? {
        presets.first { $0.name == name }
    }

    func presetForCategory(_ category: AppCategory) -> CapturePreset? {
        switch category {
        case .code:
            return preset(named: "Code Snippet")
        case .lecture:
            return preset(named: "Lecture Notes")
        case .document, .web:
            return preset(named: "Assignment")
        case .chat, .other:
            return preset(named: "Quick Capture")
        }
    }

    // MARK: - Persistence

    private func ensureBuiltInPresets() {
        for builtIn in Self.builtInPresets
            where !presets.contains(where: { $0.name == builtIn.name }) {
            presets.append(builtIn)
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: presetsKey)
        }
    }

    private func loadPresets() {
        guard let data = defaults.data(forKey: presetsKey),
              let loaded = try? JSONDecoder().decode([CapturePreset].self, from: data) else {
            return
        }
        presets = loaded
    }
}
