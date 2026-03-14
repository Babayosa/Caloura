import SwiftUI

/// Generic presenter that manages a single NSWindow hosting a SwiftUI view.
///
/// Extracts the repeated open/close/bring-to-front boilerplate shared by
/// OnboardingWindowController, NagWindowController, PreferencesWindowController,
/// HistoryWindowController, and AnnotationWindowController.
@MainActor
final class SingleWindowPresenter<Content: View> {

    struct WindowConfig {
        var title: String
        var size: CGSize
        var styleMask: NSWindow.StyleMask = [.titled, .closable]
        var minSize: CGSize?
        var autosaveName: String?
    }

    private(set) var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Shows the window with the given config and content.
    ///
    /// If the window is already visible, it is brought to front instead.
    /// Returns `true` if a new window was created, `false` if an existing
    /// window was brought to front.
    @discardableResult
    func show(
        config: WindowConfig,
        @ViewBuilder content: () -> Content
    ) -> Bool {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return false
        }

        // Clean up stale observer from previous window
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
            closeObserver = nil
        }
        window = nil

        let hostingView = NSHostingView(rootView: content())
        hostingView.frame = CGRect(origin: .zero, size: config.size)

        let newWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: config.styleMask,
            backing: .buffered,
            defer: false
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = hostingView
        newWindow.title = config.title

        if let minSize = config.minSize {
            newWindow.contentMinSize = minSize
        }
        if let autosaveName = config.autosaveName {
            newWindow.setFrameAutosaveName(autosaveName)
        }

        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()

        self.window = newWindow

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowWillClose()
            }
        }

        return true
    }

    func close() {
        window?.close()
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private func handleWindowWillClose() {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        closeObserver = nil
        window = nil
    }
}
