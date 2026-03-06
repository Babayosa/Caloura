@preconcurrency import ScreenCaptureKit

@MainActor
final class SystemWindowSharingPicker: WindowSharingPicking {
    static let shared = SystemWindowSharingPicker()

    private let picker = SCContentSharingPicker.shared

    var isActive: Bool {
        get { picker.isActive }
        set { picker.isActive = newValue }
    }

    var defaultConfiguration: SCContentSharingPickerConfiguration {
        get { picker.defaultConfiguration }
        set { picker.defaultConfiguration = newValue }
    }

    func add(_ observer: any SCContentSharingPickerObserver) {
        picker.add(observer)
    }

    func present(using style: SCShareableContentStyle) {
        picker.present(using: style)
    }
}
