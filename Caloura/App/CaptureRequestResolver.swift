import Foundation

struct CaptureRequestResolution {
    let detectedContext: DetectedContext
    let captureContext: CaptureContext
    let preset: CapturePreset
    let smartCropEnabled: Bool
}

@MainActor
final class CaptureRequestResolver {
    typealias DetectContextFn = () -> DetectedContext
    typealias PresetForCategoryFn = (AppCategory) -> CapturePreset?
    typealias PresetByNameFn = (String) -> CapturePreset?

    private let settings: AppSettings
    private let detectContext: DetectContextFn
    private let presetForCategory: PresetForCategoryFn
    private let presetByName: PresetByNameFn

    init(
        settings: AppSettings,
        detectContext: @escaping DetectContextFn,
        presetForCategory: @escaping PresetForCategoryFn,
        presetByName: @escaping PresetByNameFn
    ) {
        self.settings = settings
        self.detectContext = detectContext
        self.presetForCategory = presetForCategory
        self.presetByName = presetByName
    }

    func resolve(mode: CaptureMode) -> CaptureRequestResolution {
        let detectedContext = detectContext()
        let captureContext = CaptureContext(
            mode: mode,
            sourceAppName: detectedContext.appName,
            sourceWindowTitle: detectedContext.windowTitle
        )

        let preset: CapturePreset
        if settings.autoContextDetection {
            preset = presetForCategory(detectedContext.category)
                ?? presetByName(settings.activePreset)
                ?? CapturePreset(name: "Quick Capture")
        } else {
            preset = presetByName(settings.activePreset)
                ?? CapturePreset(name: "Quick Capture")
        }

        return CaptureRequestResolution(
            detectedContext: detectedContext,
            captureContext: captureContext,
            preset: preset,
            smartCropEnabled: settings.smartCropEnabled && preset.smartCropEnabled
        )
    }
}
