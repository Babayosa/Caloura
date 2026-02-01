import Foundation

enum CopyMode: String, Codable, CaseIterable {
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
}

@MainActor
final class PresetManager: ObservableObject {
    static let shared = PresetManager()
    static let builtInPresetNames = ["Quick Capture", "Lecture Notes", "Code Snippet", "Assignment"]

    @Published var presets: [CapturePreset] = []

    private let presetsKey = "capturePresets"

    private init() {
        loadPresets()
        ensureBuiltInPresets()
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
        for builtIn in Self.builtInPresets {
            if !presets.contains(where: { $0.name == builtIn.name }) {
                presets.append(builtIn)
            }
        }
        savePresets()
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let loaded = try? JSONDecoder().decode([CapturePreset].self, from: data) else {
            return
        }
        presets = loaded
    }
}
