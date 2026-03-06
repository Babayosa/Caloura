import Foundation
import KeyboardShortcuts

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private init() {}

    func registerAll() {
        KeyboardShortcuts.onKeyUp(for: .captureArea) {
            AppCommandRouter.shared.dispatch(.captureArea)
        }

        KeyboardShortcuts.onKeyUp(for: .captureWindow) {
            AppCommandRouter.shared.dispatch(.captureWindow)
        }

        KeyboardShortcuts.onKeyUp(for: .captureFullscreen) {
            AppCommandRouter.shared.dispatch(.captureFullscreen)
        }

        KeyboardShortcuts.onKeyUp(for: .captureRepeat) {
            AppCommandRouter.shared.dispatch(.captureRepeat)
        }

        KeyboardShortcuts.onKeyUp(for: .copyAsMarkdown) {
            AppCommandRouter.shared.dispatch(.copyLastAsMarkdown)
        }

        KeyboardShortcuts.onKeyUp(for: .copyWithCitation) {
            AppCommandRouter.shared.dispatch(.copyLastWithCitation)
        }

        KeyboardShortcuts.onKeyUp(for: .copyOCRText) {
            AppCommandRouter.shared.dispatch(.copyLastOCRText)
        }

        KeyboardShortcuts.onKeyUp(for: .captureScroll) {
            AppCommandRouter.shared.dispatch(.captureScroll)
        }
    }
}
