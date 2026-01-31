import Foundation
import KeyboardShortcuts

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private init() {}

    func registerAll() {
        KeyboardShortcuts.onKeyUp(for: .captureArea) {
            NotificationCenter.default.post(name: .captureArea, object: nil)
        }

        KeyboardShortcuts.onKeyUp(for: .captureWindow) {
            NotificationCenter.default.post(name: .captureWindow, object: nil)
        }

        KeyboardShortcuts.onKeyUp(for: .captureFullscreen) {
            NotificationCenter.default.post(name: .captureFullscreen, object: nil)
        }

        KeyboardShortcuts.onKeyUp(for: .captureRepeat) {
            NotificationCenter.default.post(name: .captureRepeat, object: nil)
        }

        KeyboardShortcuts.onKeyUp(for: .copyAsMarkdown) {
            NotificationCenter.default.post(name: .copyLastAsMarkdown, object: nil)
        }

        KeyboardShortcuts.onKeyUp(for: .copyWithCitation) {
            NotificationCenter.default.post(name: .copyLastWithCitation, object: nil)
        }

        KeyboardShortcuts.onKeyUp(for: .copyOCRText) {
            NotificationCenter.default.post(name: .copyLastOCRText, object: nil)
        }
    }
}
